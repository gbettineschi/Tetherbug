import AppKit
import CoreBluetooth
import CoreServices
import ServiceManagement
import SwiftUI

/// A filled shape from flattened path data (assets/icon/icon.py): space-separated `Mx,y`, `Lx,y` and `Z`
/// tokens in a unit square, drawn even-odd and fitted to the rect at the given aspect ratio.
struct PathShape: Shape {
    let data: String
    var aspect: Double = 1

    static let buddy = PathShape(data: buddyPathData, aspect: buddyAspect)
    static let github = PathShape(data: githubPathData)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let side = min(rect.width, rect.height * aspect)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        for token in data.split(separator: " ") {
            let command = token.first!
            if command == "Z" { path.closeSubpath(); continue }
            let xy = token.dropFirst().split(separator: ",").compactMap { Double($0) }
            let point = CGPoint(x: origin.x + xy[0] * side, y: origin.y + xy[1] * side)
            command == "M" ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// Streams the agent's state; nil while the agent isn't running.
final class AgentModel: ObservableObject {
    enum LoginStartup { case idle, repairing, unavailable }
    private static let loginStartTimeout: TimeInterval = 8

    @Published var state: AgentState?
    @Published var onNoWifi: Bool {
        didSet {
            guard !updatingFromAgent else { return }
            defaults.set(onNoWifi, forKey: "onNoWifi")
            send(onNoWifi ? "automatic on" : "automatic off")
        }
    }
    private let defaults: UserDefaults
    private var updatingFromAgent = false
    private var agentStopping = false
    var isEnding: Bool { agentStopping }
    private let launchAgent: () throws -> Process
    private let request: (String) -> Bool
    private let observation = AgentObservation()
    @Published var disconnectWait = Settings.disconnectWait { didSet { Settings.disconnectWait = disconnectWait } }
    @Published var debugNotifications = Settings.debugNotifications {
        didSet {
            Settings.debugNotifications = debugNotifications
            checkNotifications()
        }
    }
    /// False when debug notifications are on but macOS has notifications off for Tetherbug.
    @Published var notificationsAllowed = true

    /// Asks from the window, so the permission prompt comes from the app rather than the agent.
    func checkNotifications() {
        guard debugNotifications else { return }
        DispatchQueue.global().async {
            let allowed = notificationPermissionGranted()
            DispatchQueue.main.async { self.notificationsAllowed = allowed }
        }
    }
    @Published private(set) var loginItem: SMAppService.Status
    @Published var loginError: String?
    @Published private(set) var loginStartup = LoginStartup.idle
    var loginServiceUnavailable: Bool { loginStartup == .unavailable }

    private let agent = SMAppService.mainApp
    private let loginServiceStatus: () -> SMAppService.Status
    private let registration: LoginRegistration
    private let registerLoginService: () throws -> Void
    private let legacyLoginServiceStatus: () -> SMAppService.Status
    private var legacyMigrationChecked = false
    var onWorkerReady: (() -> Void)?
    var loginMigrationInFlight: Bool { registration.inFlight }
    private var afterRegistration: (() -> Void)?
    private var pendingNormalClose: ((Bool) -> Void)?
    private let closeReadinessTimeout: TimeInterval
    private var closeGeneration: UInt64 = 0
    private let isFullWake: () -> Bool
    private let uptime: () -> TimeInterval
    private var loginStartDeadline: TimeInterval?

    init(defaults: UserDefaults = Settings.defaults,
         watch: @escaping (@escaping (AgentState) -> Bool) -> Bool = { SocketClient.request("watch", onState: $0) },
         launchAgent: @escaping () throws -> Process = {
             let process = Process()
             process.executableURL = Bundle.main.executableURL
             process.arguments = ["agent"]
             try process.run()
             return process
         },
         request: @escaping (String) -> Bool = { command in
             var acknowledged = false
             let reached = SocketClient.request(command) { state in
                 acknowledged = command != "quit" || state.stopping == true
                 return false
             }
             return reached && acknowledged
         },
         loginServiceStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         legacyLoginServiceStatus: @escaping () -> SMAppService.Status = LoginRegistration.legacyStatus,
         unregisterLoginService: @escaping (@escaping (Error?) -> Void) -> Void = LoginRegistration.unregisterNative,
         registerLoginService: @escaping () throws -> Void = LoginRegistration.registerNative,
         isFullWake: @escaping () -> Bool = {
             PowerActivity.isFullWake(SystemPowerMonitor.capabilities())
         },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         closeReadinessTimeout: TimeInterval = 8) {
        self.defaults = defaults
        self.launchAgent = launchAgent
        self.request = request
        self.loginServiceStatus = loginServiceStatus
        self.legacyLoginServiceStatus = legacyLoginServiceStatus
        self.registerLoginService = registerLoginService
        self.registration = LoginRegistration(status: legacyLoginServiceStatus, allowed: isFullWake,
            unregister: unregisterLoginService, register: registerLoginService)
        self.isFullWake = isFullWake
        self.uptime = uptime
        self.closeReadinessTimeout = closeReadinessTimeout
        self.loginItem = loginServiceStatus()
        onNoWifi = defaults.object(forKey: "onNoWifi") as? Bool ?? true
        migrateLegacyLoginService()
        let observation = self.observation
        Thread.detachNewThread { [weak self] in
            while self != nil && observation.active {
                // `watch` streams until the agent goes away; then retry, so the window follows restarts.
                let connected = watch { state in
                    DispatchQueue.main.async { self?.receive(state) }
                    return observation.active
                }
                if !connected {
                    DispatchQueue.main.async {
                        guard self?.agentStopping != true else { return }
                        self?.state = nil
                        self?.recoverAgent()
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func receive(_ state: AgentState) {
        if state.stopping == true {
            if registration.inFlight {
                afterRegistration = { [weak self] in self?.quit { NSApp.terminate(nil) } }
                return
            }
            agentStopping = true
            NSApp.terminate(nil)
            return
        }
        if pendingNormalClose != nil {
            guard let pid = state.workerPID, pid == sessionAgent?.processIdentifier else { return }
        }
        clearLoginStartAttempt()
        self.state = state
        finishNormalClose(true)
        onWorkerReady?()
        if let automatic = state.automatic, automatic != onNoWifi {
            updatingFromAgent = true
            onNoWifi = automatic
            updatingFromAgent = false
        }
    }

    /// The hotspot password, fetched on demand from the agent (it isn't in the status stream).
    @Published var password: String?

    func fetchPassword(completion: @escaping (String?) -> Void = { _ in }) {
        DispatchQueue.global().async {
            var value: String?
            SocketClient.request("password") { state in
                value = state.password
                return false
            }
            DispatchQueue.main.async {
                self.password = value
                completion(value)
            }
        }
    }

    func send(_ command: String) {
        DispatchQueue.global().async { [request] in _ = request(command) }
    }

    /// Window close ends observation only; the menu-bar helper is intentionally independent.
    func closeSettings() {
        agentStopping = true
        observation.stop()
    }

    func quit(completion: @escaping () -> Void) {
        guard !agentStopping else { completion(); return }
        if registration.inFlight {
            afterRegistration = { [weak self] in self?.quit(completion: completion) }
            return
        }
        closeSettings() // prevent the watcher from treating intentional shutdown as a crash
        let child = sessionAgent
        // A worker can still be opening its socket. An owned child can be stopped directly;
        // otherwise give it the remainder of its startup window for a graceful Quit.
        let remaining = (loginStartDeadline ?? 0) - uptime()
        let pendingStartTime = loginServiceUnavailable || child?.isRunning == true ? 0 : max(0, min(Self.loginStartTimeout, remaining))
        DispatchQueue.global().async { [request] in
            let deadline = ProcessInfo.processInfo.systemUptime + pendingStartTime
            var receivedQuit = request("quit")
            while !receivedQuit && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                receivedQuit = request("quit")
            }
            let acknowledged = receivedQuit
            if !acknowledged, child?.isRunning == true {
                child?.terminate()
                child?.waitUntilExit()
            }
            DispatchQueue.main.async {
                if !acknowledged, Bundle.main.bundleIdentifier == "ie.xav.tetherbug" {
                    // Also handles an older helper that does not understand the socket Quit command.
                    // Unbundled unit tests must never terminate the actual installed app.
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ie.xav.tetherbug")
                        where app.processIdentifier != getpid() { app.terminate() }
                }
                completion()
            }
        }
    }

    /// A manually launched helper. Registration alone does not mean launchd currently has a running
    /// process; the agent's lifetime lock arbitrates a race with a launchd start.
    private var sessionAgent: Process?

    private func recoverAgent() {
        guard !agentStopping, isFullWake() else { return }
        if registration.inFlight { registration.resume(); return }
        migrateLegacyLoginService()
        guard !registration.inFlight, !loginServiceUnavailable else { return }
        refreshLoginServiceStatus()
        if let deadline = loginStartDeadline, uptime() >= deadline {
            loginStartup = .unavailable
            finishNormalClose(false)
            return
        }
        startSessionAgent()
    }

    private func migrateLegacyLoginService() {
        guard !legacyMigrationChecked, !registration.inFlight, !agentStopping, isFullWake() else { return }
        guard legacyLoginServiceStatus() == .enabled else { legacyMigrationChecked = true; return }
        loginStartup = .repairing
        let accepted = registration.begin { [weak self] error in
            guard let self else { return }
            self.legacyMigrationChecked = true
            self.refreshLoginServiceStatus()
            self.loginStartup = .idle
            if let error {
                self.loginError = error.localizedDescription
                log("couldn't migrate the legacy login agent: \(error.localizedDescription)")
            }
            let finished = self.afterRegistration
            self.afterRegistration = nil
            finished?()
        }
        if !accepted { loginStartup = .idle }
    }

    /// An enabled legacy item must be replaced by a ready session worker before normal close.
    func finishRegistrationBeforeClosing(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard registration.inFlight else { return false }
        afterRegistration = { [weak self] in
            guard let self else { completion(false); return }
            self.pendingNormalClose = completion
            self.closeGeneration &+= 1
            let generation = self.closeGeneration
            self.state = nil
            self.startSessionAgent()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.closeReadinessTimeout) { [weak self] in
                guard let self, !self.agentStopping, self.closeGeneration == generation,
                      self.pendingNormalClose != nil else { return }
                self.loginStartup = .unavailable
                self.finishNormalClose(false)
            }
        }
        return true
    }

    private func finishNormalClose(_ ready: Bool) {
        closeGeneration &+= 1
        let finished = pendingNormalClose
        pendingNormalClose = nil
        finished?(ready)
    }

    func retryLoginService() {
        guard state == nil, !registration.inFlight else { return }
        loginError = nil
        stopSessionAgent()
        clearLoginStartAttempt()
        recoverAgent()
    }

    func refreshLoginServiceStatus() {
        let status = loginServiceStatus()
        guard status != loginItem else { return }
        loginItem = status
    }

    private func clearLoginStartAttempt() {
        loginStartDeadline = nil
        if loginStartup != .idle { loginStartup = .idle }
    }

    private func startSessionAgent() {
        guard !agentStopping, sessionAgent?.isRunning != true else { return }
        do {
            sessionAgent = try launchAgent()
            loginStartDeadline = loginStartDeadline ?? uptime() + Self.loginStartTimeout
        } catch {
            loginStartup = .unavailable
            loginError = error.localizedDescription
            finishNormalClose(false)
            log("couldn't start the agent: \(error.localizedDescription)")
        }
    }

    func stopSessionAgent() {
        sessionAgent?.terminate()
        // Let it release the socket before an explicit retry starts a replacement.
        sessionAgent?.waitUntilExit()
        sessionAgent = nil
    }

    func setLoginItem(_ on: Bool) {
        guard !registration.inFlight else { return }
        loginError = nil
        legacyMigrationChecked = true
        registration.cancel()
        do {
            if on {
                try registerLoginService()
            } else {
                try agent.unregister()
            }
        } catch {
            loginError = error.localizedDescription
            log("login item: \(error.localizedDescription)")
        }
        refreshLoginServiceStatus()
        // macOS asks the user to allow new background items in System Settings first.
        if loginItem == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

private final class AgentObservation {
    private let lock = NSLock()
    private var stopped = false
    var active: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

enum Links {
    static let repo = URL(string: "https://github.com/xav-ie/Tetherbug")!
    static let setup = URL(string: "https://github.com/xav-ie/Tetherbug/blob/main/docs/macos.md")!
    static let pairing = URL(string: "https://github.com/xav-ie/Tetherbug/blob/main/docs/macos.md#2-pair-the-phone-with-your-mac")!
    static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=ie.xav.tetherbug")!
    static let bluetoothSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    static let sketchybar = URL(string: "https://github.com/xav-ie/Tetherbug/blob/main/docs/sketchybar.md")!
    static let releases = URL(string: "https://github.com/xav-ie/Tetherbug/releases")!
}

struct ContentView: View {
    @ObservedObject var model: AgentModel

    private var state: AgentState? { model.state }
    private var phone: PhoneStatus? { state?.connected == true ? state?.status : nil }
    private var canSwitch: Bool {
        phone?.controllable == true && phone?.hotspot != .starting && state?.requestPending != true
    }
    private var connection: String {
        guard let state else { return "Starting…" }
        if state.connected { return state.phone ?? "Phone connected" }
        if state.bluetooth == "on" { return "Looking for your phone…" }
        if state.bluetooth == "unauthorized" { return "Bluetooth access required" }
        return "Bluetooth is \(state.bluetooth)"
    }

    var body: some View {
        Form {
            Section("Phone") {
                LabeledContent("Connection") {
                    Text(connection).foregroundStyle(phone == nil ? .secondary : .primary)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                HStack {
                    Toggle("Hotspot", isOn: Binding(
                        get: { phone?.hotspot == .on },
                        set: { _ in model.send("toggle") }
                    ))
                    .disabled(!canSwitch)
                    if state?.requestPending == true || phone?.hotspot == .starting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let error = state?.requestError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let phone, !phone.controllable {
                    Text("Shizuku is not ready on your phone. Open Tetherbug there to check access.")
                        .foregroundStyle(.secondary).font(.callout)
                } else if state?.connected == true && phone == nil {
                    Text("Reading phone status…").foregroundStyle(.secondary)
                } else if state?.bluetooth == "unauthorized" {
                    Link("Allow Bluetooth access in System Settings", destination: Links.bluetoothSettings)
                } else if state?.connected != true {
                    Text("Keep Bluetooth on and Tetherbug running on your phone.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                LabeledContent("Network") {
                    Text(phone?.ssid.isEmpty == false ? phone!.ssid : "—")
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                PasswordRow(model: model, available: phone != nil)
                if let phone {
                    LabeledContent("Phone status", value: "\(phone.battery)% battery · Signal \(phone.signal)/4")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }

            Section("Automatic activation") {
                Toggle("Turn on hotspot when disconnected from Wi-Fi", isOn: $model.onNoWifi)
                if model.onNoWifi {
                    LabeledContent("Wait before turning on") {
                        HStack(spacing: 6) {
                            TextField("Seconds", value: Binding(
                                get: { model.disconnectWait },
                                set: { model.disconnectWait = min(600, max(0, $0)) }
                            ), format: .number.grouping(.never))
                            .labelsHidden().accessibilityLabel("Wait before turning on, seconds")
                            .frame(width: 55).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                }
                if let expiry = state?.automaticPausedUntil {
                    Text("Turned off until \(expiry.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }

            PreferredWifiSection(hotspotSSID: phone?.ssid, message: state?.wifiHandoverMessage,
                                 prefersHotspot: state?.preferHotspotUntil != nil)

            Section("General") {
                if let job = state?.managedBy {
                    LabeledContent("Launch at login", value: job.hasPrefix("org.nixos.") ? "Managed by Nix" : "Managed by launchd")
                } else {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.loginItem == .enabled || model.loginItem == .requiresApproval },
                        set: { model.setLoginItem($0) }
                    ))
                    .disabled(model.loginMigrationInFlight)
                }
                if model.loginItem == .requiresApproval {
                    Button("Allow Tetherbug in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = model.loginError { Text(error).foregroundStyle(.red).font(.callout) }
                if model.loginStartup == .repairing {
                    Text("Refreshing Tetherbug’s background service…").foregroundStyle(.secondary)
                } else if model.loginServiceUnavailable {
                    Text("Tetherbug’s background service didn’t start.").foregroundStyle(.secondary)
                    Button("Retry Background Service") { model.retryLoginService() }
                }
                Text("Closing this window keeps Tetherbug in the menu bar. Choose Quit Tetherbug to stop it.")
                    .foregroundStyle(.secondary).font(.callout)
            }

            Section("Diagnostics") {
                Toggle("Debug notifications", isOn: $model.debugNotifications)
                if model.debugNotifications, !model.notificationsAllowed {
                    Link("Allow notifications in System Settings", destination: Links.notificationSettings)
                }
            }

            Section {
                HStack {
                    Link("Help", destination: Links.setup)
                    Link("Phone app", destination: Links.releases)
                    Link("GitHub", destination: Links.repo)
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(minWidth: 500, minHeight: 560)
    }
}

struct PasswordRow: View {
    @ObservedObject var model: AgentModel
    var available: Bool
    @State private var shown = false
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        HStack {
            Text("Password")
            Spacer()
            HStack(spacing: 10) {
                Text(shown ? (model.password ?? "Loading…") : "Hidden")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(shown ? .primary : .secondary)
                    .textSelection(.enabled)
                Button(shown ? "Hide" : "Show") {
                    if !shown { model.fetchPassword() }
                    shown.toggle()
                }
                Button(copied ? "Copied" : "Copy") {
                    model.fetchPassword { value in
                        guard let value else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copies += 1
                        copied = true
                        let current = copies
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if current == copies { copied = false }
                        }
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(!available)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: available) { if !available { shown = false; copied = false } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let model = AgentModel()
    private var bluetooth: CBCentralManager?
    private var closingSettings = false
    private var launchedAtLogin = false

    func applicationDidBecomeActive(_ notification: Notification) {
        window?.deminiaturize(nil)
        model.refreshLoginServiceStatus()
        model.checkNotifications()
        if bluetooth == nil, CBManager.authorization == .notDetermined,
           PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) {
            bluetooth = CBCentralManager(delegate: nil, queue: nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginLaunch.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 690),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Tetherbug"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 560)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        NSApp.mainMenu = mainMenu()
        window.center()
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory)
            model.onWorkerReady = { [weak self] in self?.finishLoginLaunch() }
            if model.state != nil { finishLoginLaunch() }
        } else {
            showSettings()
        }
    }

    private func finishLoginLaunch() {
        guard launchedAtLogin else { return }
        launchedAtLogin = false
        model.onWorkerReady = nil
        closingSettings = true
        NSApp.terminate(nil) // a normal window close: the independent worker stays running
    }

    @objc private func showSettings() {
        closingSettings = false
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHelp() { NSWorkspace.shared.open(Links.setup) }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        let app = section("Tetherbug")
        app.addItem(withTitle: "About Tetherbug", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Tetherbug", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Tetherbug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = section("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windows = section("Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        let help = section("Help")
        let guide = help.addItem(withTitle: "Tetherbug Help", action: #selector(showHelp), keyEquivalent: "?")
        guide.target = self
        NSApp.helpMenu = help
        return menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func windowWillClose(_ notification: Notification) { closingSettings = true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closingSettings {
            return model.finishRegistrationBeforeClosing { [weak self] ready in
                if !ready, PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) { self?.showSettings() }
                sender.reply(toApplicationShouldTerminate: ready)
            }
                ? .terminateLater : .terminateNow
        }
        if model.isEnding { return .terminateNow }
        model.quit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { model.closeSettings() }
}

func runApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}
