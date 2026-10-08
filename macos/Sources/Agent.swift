import CoreBluetooth
import CoreWLAN
import Foundation
import Network
import UserNotifications

/// Background agent: keeps the Bluetooth LE link to the phone, decides when to ask for the hotspot,
/// and serves its state over a local socket to the app and the CLI.
final class Agent: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var phone: CBPeripheral?
    private var command: CBCharacteristic?
    private var credentials: CBCharacteristic?
    private var password: String? // kept in memory only
    private var server: SocketServer!
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private let scanQueue = DispatchQueue(label: "ie.xav.tetherbug.scan")
    private var offlineSince: Date?
    private var backoff: TimeInterval = 2
    private var nextRetry = Date.distantPast
    private var pendingFullScan: DispatchWorkItem? // the full-scan fallback while the frequency is unknown
    private var state = AgentState() {
        didSet { if state != oldValue { server.broadcast(state) } }
    }

    func run() {
        // One agent per user: a second copy (a login item plus a manual run, say) must not take the
        // socket from the first. A clean exit isn't restarted by launchd (KeepAlive SuccessfulExit=false).
        if SocketClient.request("status", onState: { _ in false }) {
            note("another agent is already running; exiting")
            exit(0)
        }
        server = SocketServer(path: Socket.path) { [weak self] line in self?.handle(line) }
        central = CBCentralManager(delegate: self, queue: .main)
        wifi.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.wifiChanged(path) } }
        wifi.start(queue: .main)
        // Re-evaluate retries even when nothing else changes.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        note("agent started; socket at \(Socket.path)")
        RunLoop.main.run()
    }

    // MARK: Socket requests

    private func handle(_ line: String) -> AgentState? {
        switch line {
        case "enable": request(true, reason: "manual")
        case "disable": request(false, reason: "manual")
        case "password":
            var reply = state
            reply.password = password
            return reply
        default: break
        }
        return state
    }

    // MARK: Wi-Fi trigger

    private func wifiChanged(_ path: NWPath) {
        let poweredOn = CWWiFiClient.shared().interface()?.powerOn() ?? false
        let offline = poweredOn && path.status != .satisfied
        if offline != state.wifiOffline { note(offline ? "Wi-Fi lost" : "Wi-Fi connected") }
        state.wifiOffline = offline
        if offline {
            if offlineSince == nil {
                offlineSince = Date()
                backoff = 2
                nextRetry = Date().addingTimeInterval(TimeInterval(Settings.disconnectWait))
            }
        } else {
            offlineSince = nil
        }
        tick()
    }

    private func tick() {
        guard Settings.onNoWifi, offlineSince != nil, Date() >= nextRetry else { return }
        let hotspot = state.status?.hotspot
        guard hotspot != .on, hotspot != .starting else { return }
        request(true, reason: "no Wi-Fi")
        nextRetry = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 30)
    }

    func request(_ on: Bool, reason: String) {
        state.lastRequest = "\(on ? "enable" : "disable") (\(reason)) at \(ISO8601DateFormatter().string(from: Date()))"
        guard let phone, let command else {
            note("\(on ? "enable" : "disable") requested (\(reason)) but the phone isn't connected")
            return
        }
        note("\(on ? "enable" : "disable") (\(reason))")
        phone.writeValue(Data([on ? Gatt.enable : Gatt.disable]), for: command, type: .withResponse)
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state.bluetooth = ["unknown", "resetting", "unsupported", "unauthorized", "off", "on"][min(central.state.rawValue, 5)]
        guard central.state == .poweredOn else {
            state.connected = false
            return
        }
        // A bonded phone may already be connected at the system level; otherwise scan for it.
        if let known = central.retrieveConnectedPeripherals(withServices: [Gatt.service]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: [Gatt.service])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        central.stopScan()
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        phone = peripheral
        peripheral.delegate = self
        state.phone = peripheral.name
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        note("connected to \(peripheral.name ?? "phone")")
        state.connected = true
        peripheral.discoverServices([Gatt.service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        note("disconnected: \(error?.localizedDescription ?? "no error")")
        state.connected = false
        command = nil
        credentials = nil
        // A pending connect has no timeout: the link comes back as soon as the phone is in range.
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        note("connect failed: \(error?.localizedDescription ?? "unknown")")
        central.connect(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Gatt.service }) else { return }
        peripheral.discoverCharacteristics([Gatt.status, Gatt.command, Gatt.credentials], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Gatt.status:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case Gatt.command:
                command = characteristic
            case Gatt.credentials:
                credentials = characteristic
                peripheral.readValue(for: characteristic)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { return note("read failed: \(error.localizedDescription)") }
        if characteristic.uuid == Gatt.credentials, let value = characteristic.value {
            password = String(decoding: value, as: UTF8.self)
            return
        }
        guard characteristic.uuid == Gatt.status, let value = characteristic.value, let status = PhoneStatus(value) else { return }
        // Re-read the password whenever the hotspot comes on, in case it was changed on the phone.
        if status.hotspot != state.status?.hotspot { note("phone hotspot \(status.hotspot.rawValue)") }
        if status.hotspot == .on, state.status?.hotspot != .on || (state.status?.frequency == 0 && status.frequency != 0) {
            refreshWifiScan(status)
        }
        if status.hotspot == .on, state.status?.hotspot != .on, let credentials { peripheral.readValue(for: credentials) }
        state.status = status
        tick()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { note("command failed: \(error.localizedDescription)") }
    }

    /// The Wi-Fi menu lists macOS's last scan, which predates a hotspot that just came on. Given the
    /// hotspot's frequency, scan just that channel every 250 ms until the hotspot shows up (it may not
    /// be broadcasting yet), for up to 10 s; CoreWiFi results carry names, so match its SSID as well
    /// as the Personal Hotspot flag. Otherwise fall back to full scans.
    private func refreshWifiScan(_ status: PhoneStatus) {
        pendingFullScan?.cancel()
        guard let scanner = ChannelScanner.shared else { return fullWifiScan() }
        guard let channel = scanner.channel(frequency: status.frequency) else {
            // The phone reports "on" just before Android tells it the frequency; a full scan started
            // now would hold up the channel scan behind it, so give the frequency a moment.
            let fallback = DispatchWorkItem { [weak self] in self?.fullWifiScan() }
            pendingFullScan = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
            return
        }
        note("scanning for the hotspot on \(status.frequency) MHz")
        scanQueue.async { [weak self] in
            let start = Date()
            var seen = false
            repeat {
                guard let networks = scanner.scan(channel) else {
                    DispatchQueue.main.async { self?.note("channel scan failed"); self?.fullWifiScan() }
                    return
                }
                seen = networks.contains { isPersonalHotspot($0) || (!status.ssid.isEmpty && networkName($0) == status.ssid) }
                if !seen { Thread.sleep(forTimeInterval: 0.25) }
            } while !seen && Date().timeIntervalSince(start) < 10
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            DispatchQueue.main.async { self?.note("hotspot \(seen ? "seen" : "not seen") after \(elapsed) s") }
        }
    }

    /// A full scan sweeps every channel (~12 s), and airportd gives a process at most one per 10 s
    /// (counted from the end of the last), so the one retry waits that long. It can only match the
    /// Personal Hotspot flag: macOS hides network names here without Location access.
    private func fullWifiScan(attempt: Int = 1) {
        note("scanning for the hotspot (attempt \(attempt))")
        DispatchQueue.global().async { [weak self] in
            let networks = (try? CWWiFiClient.shared().interface()?.scanForNetworks(withName: nil)) ?? []
            let found = networks.contains(where: isPersonalHotspot)
            DispatchQueue.main.async {
                guard !found, attempt < 2 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    guard let self, self.state.status?.hotspot == .on else { return }
                    self.fullWifiScan(attempt: attempt + 1)
                }
            }
        }
    }

    /// Logs, and with debug notifications on also posts the line as a notification.
    private func note(_ message: String) {
        log(message)
        guard Settings.debugNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Tetherbug"
            content.body = message
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// The phone restarted its GATT service (app update, service restart): the old characteristics
    /// are gone, so rediscover and re-subscribe instead of writing into the void.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        note("phone's service changed; rediscovering")
        command = nil
        credentials = nil
        peripheral.discoverServices([Gatt.service])
    }
}

/// Whether macOS saw Apple's Personal Hotspot element in the network's beacon (the private
/// `isPersonalHotspot` of CWNetwork and CWFScanResult; false if a macOS release drops it).
func isPersonalHotspot(_ network: NSObject) -> Bool {
    guard network.responds(to: NSSelectorFromString("isPersonalHotspot")) else { return false }
    return (network.value(forKey: "isPersonalHotspot") as? Bool) ?? false
}

/// A CWFScanResult's network name, which CoreWiFi doesn't hide without Location access.
func networkName(_ network: NSObject) -> String? {
    guard network.responds(to: NSSelectorFromString("networkName")) else { return nil }
    return network.value(forKey: "networkName") as? String
}

/// CoreWiFi's scan of chosen channels, loaded at runtime so the app links no private framework; nil
/// when CoreWiFi or a call it needs is missing. Scanning one channel takes a fraction of a second,
/// isn't held to airportd's one full scan per 10 s, and updates the scan cache the Wi-Fi menu shows.
final class ChannelScanner {
    static let shared = ChannelScanner()
    private static let scanSelector = NSSelectorFromString("performScanWithParameters:error:")
    private typealias Scan = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
    private let interface: NSObject
    private let parametersClass: NSObject.Type
    private let channelClass: NSObject.Type

    private init?() {
        let responds = { (type: NSObject.Type, selectors: [String]) in selectors.allSatisfy { type.instancesRespond(to: NSSelectorFromString($0)) } }
        guard dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_LAZY) != nil,
              let interfaceClass = NSClassFromString("CWFInterface") as? NSObject.Type,
              let parametersClass = NSClassFromString("CWFScanParameters") as? NSObject.Type,
              let channelClass = NSClassFromString("CWFChannel") as? NSObject.Type,
              responds(interfaceClass, ["activate", "performScanWithParameters:error:"]),
              responds(parametersClass, ["setChannels:"]),
              responds(channelClass, ["setChannel:", "setFlags:"]),
              CWChannel.instancesRespond(to: NSSelectorFromString("flags"))
        else { return nil }
        interface = interfaceClass.init()
        interface.perform(NSSelectorFromString("activate"))
        self.parametersClass = parametersClass
        self.channelClass = channelClass
    }

    /// The 20 MHz channel at `frequency` MHz with the flags macOS gives it (band, DFS, passive), or
    /// nil if the frequency is unknown or this Mac can't use it.
    func channel(frequency: Int) -> NSObject? {
        let number: Int, band: CWChannelBand
        switch frequency {
        case 2484: (number, band) = (14, .band2GHz)
        case 2412...2472: (number, band) = ((frequency - 2407) / 5, .band2GHz)
        case 5160...5885: (number, band) = ((frequency - 5000) / 5, .band5GHz)
        case 5935: (number, band) = (2, .band6GHz)
        case 5955...7115: (number, band) = ((frequency - 5950) / 5, .band6GHz)
        default: return nil
        }
        let supported = CWWiFiClient.shared().interface()?.supportedWLANChannels()?.first {
            $0.channelNumber == number && $0.channelBand == band && $0.channelWidth == .width20MHz
        }
        guard let flags = supported?.value(forKey: "flags") as? Int else { return nil }
        let channel = channelClass.init()
        channel.setValue(number, forKey: "channel")
        channel.setValue(flags, forKey: "flags")
        return channel
    }

    /// Scans `channel` live (blocking); nil on failure.
    func scan(_ channel: NSObject) -> [NSObject]? {
        let parameters = parametersClass.init()
        parameters.setValue([channel], forKey: "channels")
        let perform = unsafeBitCast(interface.method(for: Self.scanSelector), to: Scan.self)
        var error: NSError?
        let results = perform(interface, Self.scanSelector, parameters, &error) as? [NSObject]
        return error == nil ? results : nil
    }
}

func log(_ message: String) {
    FileHandle.standardError.write("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8)!)
}
