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
final class Agent: NSObject {
    private var central: CBCentralManager!
    private var phone: CBPeripheral?
    private var command: CBCharacteristic?
    private var credentials: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var statusReceiver = PhoneStatusReceiver()
    private var statusSubscription = PhoneStatusSubscription()
    private var password: String? // kept in memory only
    private var server: SocketServer!
    private var agentLock: AgentLock?
    private let isLoginAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == loginAgentLabel
    private var exiting = false
    private var outstandingWrite: CBCharacteristic?
    private var reconnectRequested = false
    private var recovery = BluetoothRecovery(preferred: Settings.preferredPhone)
    private let activity: PowerActivity
    private var powerMonitor: SystemPowerMonitor?
    private var bluetoothCallbacks: BluetoothCallbacks?
    private var maintenance: Timer?
    private var nextReadinessCheck = Date.distantPast
    private let control = HotspotControl()
    private let wifiPreference = WifiPreferenceControl()
    private var menuBar: MenuBarController?
    private var wifi: NWPathMonitor?
    private let scanQueue = DispatchQueue(label: "ie.xav.tetherbug.scan")
    private lazy var wifiScanner = MacWifiPresenceScanner(activity: activity, queue: scanQueue)
    private lazy var preferredPresence = PreferredWifiPresence(scanner: wifiScanner,
        context: { [unowned self] in self.presenceContext() },
        turnOff: { [weak self] in self?.request(false, reason: "preferred Wi-Fi available") },
        report: { [weak self] in self?.state.preferredWifiMessage = $0 })
    private var offlineSince: Date?
    private var backoff: TimeInterval = 2
    private var nextRetry = Date.distantPast
    private var state = AgentState() {
        didSet {
            if state != oldValue {
                server?.broadcast(state)
                menuBar?.update(state)
            }
        }
    }

    init(capabilities: @escaping () -> UInt32? = SystemPowerMonitor.capabilities) {
        activity = PowerActivity(capabilities: capabilities)
        super.init()
        activity.update(.startup)
    }

    func run() {
        Settings.defaults.removeObject(forKey: "returnToPreferredWifi")
        // A login service can take over from a session worker left behind after Settings closed.
        // It must own the lock before binding the socket or starting Bluetooth.
        let handover: (() -> AgentLock.Handover)? = isLoginAgent && activity.active ? {
            var result = AgentLock.Handover.unavailable
            SocketClient.request("handover") { reply in
                result = reply.handoverAccepted == true ? .accepted : .declined
                return false
            }
            return result
        } : nil
        guard let lease = AgentLock.acquire(path: Socket.path + ".lock", handover: handover) else {
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
        state.workerPID = getpid()
        server = SocketServer(path: Socket.path) { [weak self] line in self?.handle(line) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        menuBar = MenuBarController(
            onToggle: { [weak self] in self?.toggleFromMenu() },
            onAutomatic: { [weak self] active in
                self?.control.setAutomaticActive(active)
                self?.automaticControlChanged()
            },
            onPauseAutomatic: { [weak self] duration in
                self?.control.pauseAutomatic(for: duration)
                self?.automaticControlChanged()
            },
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        app.delegate = menuBar
        publishControl()
        let monitor = SystemPowerMonitor { [weak self] in self?.powerChanged($0) }
        powerMonitor = monitor
        if monitor.start() { powerChanged(.startup) }
        else {
            activity.update(.willSleep) // no reliable sleep notifications: fail closed
            log("power monitoring unavailable; radio disabled")
        }
        note("agent started; socket at \(Socket.path)")
        app.run()
    }

    // MARK: Socket requests

    func handle(_ line: String) -> AgentState? {
        switch line {
        case "enable": request(true, reason: "manual")
        case "disable": request(false, reason: "manual")
        case "toggle": toggleFromMenu()
        case "automatic on": setAutomatic(true)
        case "automatic off": setAutomatic(false)
        case "quit": quit()
        case "handover":
            guard !isLoginAgent, state.managedBy == nil, !exiting else { return state }
            quit(closeSettings: false)
            // Acknowledge only to the successor. The Settings watcher must stay open to reconnect.
            var reply = state
            reply.handoverAccepted = true
            return reply
        case "password":
            var reply = state
            reply.password = password
            return reply
        default: break
        }
        return state
    }

    // MARK: Wi-Fi trigger

    private func powerChanged(_ event: PowerActivity.Event) {
        activity.update(event)
        if activity.active, state.stopping != true {
            if central == nil { resumeRadio() }
        } else { suspendRadio() }
    }

    /// Called on the main queue at every radio entry point, including delegate callbacks.
    private func radioAllowed(_ token: UInt64? = nil) -> Bool {
        guard state.stopping != true else { return false }
        let generation = activity.generation
        guard token == nil || token == generation else { return false }
        guard activity.allows(generation) else {
            powerChanged(.capabilitiesChanged)
            return false
        }
        return true
    }

    private func resumeRadio() {
        let token = activity.generation
        recovery.restart()
        offlineSince = nil
        state.wifiOffline = false
        backoff = 2
        nextRetry = .distantPast
        nextReadinessCheck = .distantPast
        let callbacks = BluetoothCallbacks(agent: self) { [weak self] in self?.radioAllowed(token) == true }
        bluetoothCallbacks = callbacks
        central = CBCentralManager(delegate: callbacks, queue: .main)
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifi = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.radioAllowed(token) else { return }
            self.wifiChanged(path)
        }
        monitor.start(queue: .main)
        maintenance = scheduleAgentMaintenance { [weak self] in
            guard let self, self.radioAllowed(token) else { return }
            self.tick()
        }
        log("radio resumed for FullWake (generation \(token))")
    }

    private func suspendRadio() {
        preferredPresence.cancel()
        maintenance?.invalidate()
        maintenance = nil
        wifi?.cancel()
        wifi = nil
        let hadRadio = central != nil
        central?.delegate = nil
        clearPhoneConnection()
        central = nil
        bluetoothCallbacks = nil
        offlineSince = nil
        state.wifiOffline = false
        state.bluetooth = "suspended"
        if hadRadio { log("radio suspended for sleep/DarkWake") }
    }

    private func wifiChanged(_ path: NWPath) {
        refreshWifiLink()
        tick()
    }

    private func refreshWifiLink() {
        let interface = CWWiFiClient.shared().interface()
        let link = interface?.interfaceName.flatMap { WifiAccess.linkActive(device: $0) }
        let offline = WifiAccess.isDisconnected(poweredOn: interface?.powerOn() == true, linkActive: link)
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
    }

    private func tick() {
        guard radioAllowed() else { return }
        refreshWifiLink()
        maintainConnection()
        if let action = statusSubscription.due() {
            applyStatusAction(action)
            return
        }
        // Shizuku can recover without an AP/battery notification from Android. Read its current
        // readiness while unavailable, rather than leaving an old "not ready" snapshot forever.
        if state.connected, state.status?.controllable == false, Date() >= nextReadinessCheck,
           let phone, let statusCharacteristic {
            nextReadinessCheck = Date().addingTimeInterval(10)
            phone.readValue(for: statusCharacteristic)
        }
        control.refresh(state)
        wifiPreference.refresh()
        publishControl()
        preferredPresence.tick()
        if control.needsReconnect {
            if state.stopping != true, !reconnectRequested, let phone {
                reconnectRequested = true
                central.cancelPeripheralConnection(phone)
            }
            return
        }
        guard state.stopping != true, !preferredPresence.blocksAutomaticEnable, control.shouldAutomaticallyEnable(state, phoneReady: statusReceiver.ready && statusSubscription.ready),
              command != nil, offlineSince != nil, Date() >= nextRetry else { return }
        request(true, reason: "no Wi-Fi")
        nextRetry = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 30)
    }

    func request(_ on: Bool, reason: String) {
        guard radioAllowed() else { return }
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
        guard radioAllowed() else { return }
        preferredPresence.cancel()
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
        automaticControlChanged()
    }

    private func automaticControlChanged() {
        preferredPresence.cancel()
        publishControl()
        backoff = 2
        nextRetry = max(Date(), (offlineSince ?? Date()).addingTimeInterval(TimeInterval(Settings.disconnectWait)))
        tick()
    }

    private func presenceContext() -> PreferredWifiPresence.Context {
        var c = PreferredWifiPresence.Context(allowed: activity.allows(activity.generation) && state.stopping != true,
            automaticActive: control.automaticActive(),
            phoneReady: state.connected && statusReceiver.ready && statusSubscription.ready && state.status?.controllable == true,
            canTurnOff: control.canToggle(state), hotspotOn: state.status?.hotspot == .on,
            wifiDisconnected: state.wifiOffline, wifiPoweredOn: false, locationAllowed: false,
            preferred: Settings.preferredWifiNetworks, hotspotSSID: state.status?.ssid)
        c.courtesyElapsed = wifiPreference.canTurnOff()
        guard c.allowed, c.automaticActive, c.phoneReady,
              !c.identities.isEmpty else { return c }
        c.locationAllowed = wifiScanner.locationAllowed
        if c.locationAllowed {
            // This snapshot is also taken at asynchronous completion, before a delayed
            // timer/path notification could otherwise miss the user's native network choice.
            refreshWifiLink()
            let interface = CWWiFiClient.shared().interface()
            wifiPreference.observeNetwork(interface?.ssid(), disconnected: state.wifiOffline)
            c.wifiDisconnected = state.wifiOffline
            c.wifiPoweredOn = interface?.powerOn() == true
            c.courtesyElapsed = wifiPreference.canTurnOff()
        }
        return c
    }

    private func publishControl() {
        var snapshot = state
        snapshot.automatic = control.automatic
        snapshot.automaticPausedUntil = control.pausedUntil
        snapshot.requestPending = control.isPending
        snapshot.requestError = control.error
        snapshot.preferredWifiOffNotBefore = wifiPreference.offNotBefore
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

    private func quit(closeSettings: Bool = true) {
        guard !exiting else { return }
        exiting = true
        if closeSettings { state.stopping = true }
        activity.update(.willSleep)
        suspendRadio()
        powerMonitor?.stop()
        if closeSettings {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ie.xav.tetherbug")
                where app.processIdentifier != getpid() && app.activationPolicy == .regular {
                app.terminate()
            }
        }
        // Let the settings watcher receive `stopping` before the socket closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    // MARK: Bluetooth

    private func maintainConnection() {
        guard radioAllowed(), let central else { return }
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
        statusReceiver = PhoneStatusReceiver()
        statusSubscription = PhoneStatusSubscription()
        password = nil
        outstandingWrite = nil
        reconnectRequested = false
        state.connected = false
        state.status = nil
        control.refresh(state)
        publishControl()
        central?.stopScan()
        if let old, old.state != .disconnected { central?.cancelPeripheralConnection(old) }
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
        peripheral.delegate = bluetoothCallbacks
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
                applyStatusAction(statusSubscription.begin())
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
        guard characteristic === statusCharacteristic, statusSubscription.acceptsValue,
              let value = characteristic.value, command != nil,
              let status = statusReceiver.receive(value, notification: statusSubscription.notification),
              recovery.receivedStatus(from: peripheral.identifier) else { return }
        if let action = statusSubscription.readCompleted() { applyStatusAction(action) }
        else if !statusReceiver.ready { applyStatusAction(statusSubscription.begin()) }
        Settings.preferredPhone = recovery.preferred
        central.stopScan()
        nextReadinessCheck = Date().addingTimeInterval(10)
        // Re-read the password whenever the hotspot comes on, in case it was changed on the phone.
        if status.hotspot != state.status?.hotspot { note("phone hotspot \(status.hotspot.rawValue)") }
        if status.hotspot == .on, state.status?.hotspot != .on, let credentials { peripheral.readValue(for: credentials) }
        state.status = status
        control.refresh(state, receivedStatus: true)
        tick()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard phone === peripheral, characteristic === statusCharacteristic else { return }
        if let action = statusSubscription.changed(notifying: characteristic.isNotifying, failed: error != nil) {
            applyStatusAction(action)
        }
    }

    private func applyStatusAction(_ action: PhoneStatusSubscription.Action) {
        guard let phone, let characteristic = statusCharacteristic else { return }
        switch action {
        case .unsubscribe: phone.setNotifyValue(false, for: characteristic)
        case .read: phone.readValue(for: characteristic)
        case .subscribe: phone.setNotifyValue(true, for: characteristic)
        case .reconnect:
            note("hotspot status subscription failed or stalled; reconnecting")
            recovery.disconnected()
            clearPhoneConnection()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard phone === peripheral, characteristic.uuid == Gatt.command, characteristic === outstandingWrite else { return }
        outstandingWrite = nil
        control.writeCompleted(error: error?.localizedDescription)
        publishControl()
        if let error { note("command failed: \(error.localizedDescription)") }
    }

    /// Logs, and with debug notifications on also posts the line as a notification.
    private func note(_ message: String) {
        log(message)
        guard Settings.debugNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let token = activity.generation
        let activity = self.activity
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted, activity.allows(token) else { return }
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

func log(_ message: String) {
    FileHandle.standardError.write("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8)!)
}
