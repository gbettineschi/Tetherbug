import AppKit
import CoreBluetooth
import CoreWLAN
import Foundation
import Network
import UserNotifications

/// Keep the existing maintenance timer active while the native dropdown tracks events.
@discardableResult
func scheduleAgentMaintenance(_ tick: @escaping () -> Void) -> Timer {
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
}

/// Background agent: keeps the Bluetooth LE link to the phone, decides when to ask for the hotspot,
/// and serves its state over a local socket to the app and the CLI.
final class Agent: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var phone: CBPeripheral?
    private var command: CBCharacteristic?
    private var credentials: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var password: String? // kept in memory only
    private var server: SocketServer!
    private var agentLock: AgentLock?
    private var outstandingWrite: CBCharacteristic?
    private var reconnectRequested = false
    private var recovery = BluetoothRecovery(preferred: Settings.preferredPhone)
    private var wakeObserver: NSObjectProtocol?
    private var nextReadinessCheck = Date.distantPast
    private let control = HotspotControl()
    private var menuBar: MenuBarController?
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private let scanQueue = DispatchQueue(label: "ie.xav.tetherbug.scan")
    private var offlineSince: Date?
    private var backoff: TimeInterval = 2
    private var nextRetry = Date.distantPast
    private var pendingFullScan: DispatchWorkItem? // the full-scan fallback while the frequency is unknown
    private var state = AgentState() {
        didSet {
            if state != oldValue {
                server?.broadcast(state)
                menuBar?.update(state)
            }
        }
    }

    func run() {
        guard let lease = AgentLock(path: Socket.path + ".lock") else {
            note("cannot acquire the agent lock; another agent may be running")
            return
        }
        agentLock = lease
        // One agent per user: a second copy (a login item plus a manual run, say) must not take the
        // socket from the first. A clean exit isn't restarted by launchd (KeepAlive SuccessfulExit=false).
        if SocketClient.request("status", onState: { _ in false }) {
            note("another agent is already running; exiting")
            exit(0)
        }
        server = SocketServer(path: Socket.path) { [weak self] line in self?.handle(line) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        menuBar = MenuBarController(
            onToggle: { [weak self] in self?.toggleFromMenu() },
            onAutomatic: { [weak self] on in self?.setAutomatic(on) },
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        app.delegate = menuBar
        publishControl()
        central = CBCentralManager(delegate: self, queue: .main)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.clearPhoneConnection()
            self?.recovery.restart()
            self?.maintainConnection()
        }
        wifi.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.wifiChanged(path) } }
        wifi.start(queue: .main)
        // Re-evaluate retries even when nothing else changes.
        scheduleAgentMaintenance { [weak self] in self?.tick() }
        note("agent started; socket at \(Socket.path)")
        app.run()
    }

    // MARK: Socket requests

    private func handle(_ line: String) -> AgentState? {
        switch line {
        case "enable": request(true, reason: "manual")
        case "disable": request(false, reason: "manual")
        case "toggle": toggleFromMenu()
        case "automatic on": setAutomatic(true)
        case "automatic off": setAutomatic(false)
        case "quit": quit()
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
        guard state.stopping != true else { return }
        maintainConnection()
        // Shizuku can recover without an AP/battery notification from Android. Read its current
        // readiness while unavailable, rather than leaving an old "not ready" snapshot forever.
        if state.connected, state.status?.controllable == false, Date() >= nextReadinessCheck,
           let phone, let statusCharacteristic {
            nextReadinessCheck = Date().addingTimeInterval(10)
            phone.readValue(for: statusCharacteristic)
        }
        control.refresh(state)
        publishControl()
        if control.needsReconnect {
            if state.stopping != true, !reconnectRequested, let phone {
                reconnectRequested = true
                central.cancelPeripheralConnection(phone)
            }
            return
        }
        guard state.stopping != true, control.shouldAutomaticallyEnable(state),
              command != nil, offlineSince != nil, Date() >= nextRetry else { return }
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
        guard control.beginRequest(on, state: state) else { return }
        publishControl()
        guard control.writePending else { return } // already at the requested state
        note("\(on ? "enable" : "disable") (\(reason))")
        outstandingWrite = command
        phone.writeValue(Data([on ? Gatt.enable : Gatt.disable]), for: command, type: .withResponse)
    }

    private func toggleFromMenu() {
        guard let phone, let command, let on = control.toggle(state) else { return }
        state.lastRequest = "\(on ? "enable" : "disable") (menu) at \(ISO8601DateFormatter().string(from: Date()))"
        // Publish the pause before issuing Off, so no retry can immediately turn it back on.
        publishControl()
        note("\(on ? "enable" : "disable") (menu)")
        outstandingWrite = command
        phone.writeValue(Data([on ? Gatt.enable : Gatt.disable]), for: command, type: .withResponse)
    }

    private func setAutomatic(_ on: Bool) {
        control.automatic = on
        backoff = 2
        nextRetry = max(Date(), (offlineSince ?? Date()).addingTimeInterval(TimeInterval(Settings.disconnectWait)))
        tick()
    }

    private func publishControl() {
        var snapshot = state
        snapshot.automatic = control.automatic
        snapshot.automaticPausedUntil = control.pausedUntil
        snapshot.requestPending = control.isPending
        snapshot.requestError = control.error
        state = snapshot
    }

    private func openSettings() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "ie.xav.tetherbug")
        if let window = others.first(where: { $0.processIdentifier != getpid() && $0.activationPolicy == .regular }) {
            window.activate(options: [.activateAllWindows])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        // An accessory agent shares the bundle ID; a normal open would target the agent itself.
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.note("couldn't open settings: \(error.localizedDescription)") } }
        }
    }

    private func quit() {
        guard state.stopping != true else { return }
        state.stopping = true
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ie.xav.tetherbug")
            where app.processIdentifier != getpid() && app.activationPolicy == .regular {
            app.terminate()
        }
        // Let the settings watcher receive `stopping` before the socket closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    // MARK: Bluetooth

    private func maintainConnection() {
        guard state.stopping != true else { return }
        switch recovery.due(poweredOn: central.state == .poweredOn) {
        case .discover:
            let known = central.retrieveConnectedPeripherals(withServices: [Gatt.service])
                .first { recovery.accepts($0.identifier) }
            if let known { connect(known) }
            else if let id = recovery.preferred,
                    let saved = central.retrievePeripherals(withIdentifiers: [id]).first { connect(saved) }
            if !central.isScanning { central.scanForPeripherals(withServices: [Gatt.service]) }
        case .resetConnection:
            note("Bluetooth connection stalled; rediscovering the phone")
            clearPhoneConnection()
        case nil: break
        }
    }

    /// Invalidates old characteristics and write ownership before any new connection can be used.
    private func clearPhoneConnection() {
        let old = phone
        phone = nil
        old?.delegate = nil
        command = nil
        credentials = nil
        statusCharacteristic = nil
        password = nil
        outstandingWrite = nil
        reconnectRequested = false
        state.connected = false
        state.status = nil
        control.refresh(state)
        publishControl()
        central.stopScan()
        if let old, old.state != .disconnected { central.cancelPeripheralConnection(old) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state.bluetooth = ["unknown", "resetting", "unsupported", "unauthorized", "off", "on"][min(central.state.rawValue, 5)]
        guard central.state == .poweredOn else {
            clearPhoneConnection()
            recovery.restart()
            return
        }
        recovery.restart()
        maintainConnection()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard recovery.beginConnection(to: peripheral.identifier) else { return }
        phone = peripheral
        peripheral.delegate = self
        state.phone = peripheral.name
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard phone === peripheral else { return }
        note("connected to \(peripheral.name ?? "phone")")
        state.status = nil // wait for a fresh report after reconnecting
        state.connected = true
        recovery.connected()
        peripheral.discoverServices([Gatt.service])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard phone === peripheral, peripheral.state == .disconnected else { return }
        note("disconnected: \(error?.localizedDescription ?? "no error")")
        recovery.disconnected()
        clearPhoneConnection()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard phone === peripheral, peripheral.state == .disconnected else { return }
        note("connect failed: \(error?.localizedDescription ?? "unknown")")
        recovery.disconnected()
        clearPhoneConnection()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phone === peripheral, error == nil else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Gatt.service }) else { return }
        peripheral.discoverCharacteristics([Gatt.status, Gatt.command, Gatt.credentials], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard phone === peripheral, error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Gatt.status:
                statusCharacteristic = characteristic
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
        guard phone === peripheral else { return }
        if let error { return note("read failed: \(error.localizedDescription)") }
        if characteristic === credentials, let value = characteristic.value {
            password = String(decoding: value, as: UTF8.self)
            return
        }
        guard characteristic === statusCharacteristic, let value = characteristic.value,
              let status = PhoneStatus(value), command != nil,
              recovery.receivedStatus(from: peripheral.identifier) else { return }
        Settings.preferredPhone = recovery.preferred
        central.stopScan()
        nextReadinessCheck = Date().addingTimeInterval(10)
        // Re-read the password whenever the hotspot comes on, in case it was changed on the phone.
        if status.hotspot != state.status?.hotspot { note("phone hotspot \(status.hotspot.rawValue)") }
        if status.hotspot == .on, state.status?.hotspot != .on || (state.status?.frequency == 0 && status.frequency != 0) {
            refreshWifiScan(status)
        }
        if status.hotspot == .on, state.status?.hotspot != .on, let credentials { peripheral.readValue(for: credentials) }
        state.status = status
        control.refresh(state, receivedStatus: true)
        tick()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Gatt.command, characteristic === outstandingWrite else { return }
        outstandingWrite = nil
        control.writeCompleted(error: error?.localizedDescription)
        publishControl()
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
        guard phone === peripheral, invalidatedServices.contains(where: { $0.uuid == Gatt.service }) else { return }
        note("phone's service changed; rediscovering")
        clearPhoneConnection()
        recovery.restart()
        maintainConnection()
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
