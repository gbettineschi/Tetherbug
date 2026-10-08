import AppKit
import CoreBluetooth
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
    @Published var state: AgentState?
    @Published var onNoWifi = Settings.onNoWifi { didSet { Settings.onNoWifi = onNoWifi } }
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
    @Published var loginItem = SMAppService.agent(plistName: "ie.xav.tetherbug.agent.plist").status

    private let agent = SMAppService.agent(plistName: "ie.xav.tetherbug.agent.plist")

    init() {
        Thread.detachNewThread { [weak self] in
            while self != nil {
                // `watch` streams until the agent goes away; then retry, so the window follows restarts.
                let connected = SocketClient.request("watch") { state in
                    DispatchQueue.main.async { self?.state = state }
                    return true
                }
                if !connected {
                    DispatchQueue.main.async {
                        self?.state = nil
                        self?.startSessionAgent()
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// The hotspot password, fetched on demand from the agent (it isn't in the status stream).
    @Published var password: String?

    func fetchPassword() {
        DispatchQueue.global().async {
            SocketClient.request("password") { state in
                DispatchQueue.main.async { self.password = state.password }
                return false
            }
        }
    }

    func send(_ command: String) {
        DispatchQueue.global().async { SocketClient.request(command) { _ in false } }
    }

    /// An agent the window runs while it's open, when nothing else does (the login item is off and no
    /// launchd job or script started one).
    private var sessionAgent: Process?

    private func startSessionAgent() {
        guard loginItem != .enabled, sessionAgent?.isRunning != true else { return }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["agent"]
        do {
            try process.run()
            sessionAgent = process
        } catch {
            log("couldn't start the agent: \(error.localizedDescription)")
        }
    }

    func stopSessionAgent() {
        sessionAgent?.terminate()
        // Let it release the socket, or the login item's agent would find it and step aside.
        sessionAgent?.waitUntilExit()
        sessionAgent = nil
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on {
                stopSessionAgent()
                try agent.register()
            } else {
                try agent.unregister()
            }
        } catch {
            log("login item: \(error.localizedDescription)")
        }
        loginItem = agent.status
        // macOS asks the user to allow new background items in System Settings first.
        if loginItem == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
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
    @Environment(\.colorScheme) private var scheme
    @StateObject private var keyboard = KeyboardFocus()

    var body: some View {
        let palette = Palette.current(scheme)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tetherbug").font(.custom("Palatino", size: 34).weight(.semibold))
                    Text("Instant Hotspot for your Mac").opacity(0.75)
                }
                Spacer()
                PathShape.buddy.fill(palette.foreground, style: FillStyle(eoFill: true)).frame(width: 96, height: 60)
                    .accessibilityHidden(true)
                WindowControls(palette: palette)
            }
            // The header (and the band above it) is the window's drag handle.
            .padding(.top, 22)
            .background(WindowDragArea().padding(.horizontal, -18))

            Card(palette: palette, label: "Status") { status(palette) }

            Card(palette: palette, title: "Settings") {
                Toggle("Turn on hotspot when Wi-Fi is disconnected", isOn: $model.onNoWifi)
                if model.onNoWifi {
                    SecondsField(title: "After disconnected for", seconds: $model.disconnectWait, range: 0...600, palette: palette)
                        // Indented: it qualifies the switch above.
                        .padding(.leading, 16)
                }
                if let job = model.state?.managedBy {
                    // Something else (nix-darwin, say) runs the agent; the login item would only add a
                    // second copy that steps aside, so show who's in charge instead of the switch.
                    HStack {
                        Text("Run in the background")
                        Spacer()
                        Text(job.hasPrefix("org.nixos.") ? "Managed by Nix" : "Managed by launchd").opacity(0.7)
                    }
                    Text("Your configuration starts the agent at login (\(job)).").font(.caption).opacity(0.7)
                } else {
                    Toggle("Run in the background", isOn: Binding(
                        get: { model.loginItem == .enabled },
                        set: { model.setLoginItem($0) }
                    ))
                    Text("Starts at login and keeps working when this window is closed.").font(.caption).opacity(0.7)
                }
                if model.loginItem == .requiresApproval {
                    Text("Allow Tetherbug under System Settings → General → Login Items.").font(.caption).opacity(0.7)
                }
                Toggle("Debug notifications", isOn: $model.debugNotifications)
                Text("Posts a notification for everything the background agent does.").font(.caption).opacity(0.7)
                if model.debugNotifications, !model.notificationsAllowed {
                    Text("Notifications are off for Tetherbug.").font(.caption).opacity(0.7)
                    SiteLink("Open Notifications settings →", url: Links.notificationSettings, palette: palette)
                }
            }

            Card(palette: palette, title: "Using SketchyBar?") {
                Text("Show your phone's hotspot state and battery in the bar, and turn the hotspot on with a click.")
                    .opacity(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                SiteLink("Add Tetherbug to SketchyBar →", url: Links.sketchybar, palette: palette)
            }

            HStack(spacing: 16) {
                SiteLink(title: "Setup guide", url: Links.setup, palette: palette) { Image(systemName: "book.closed") }
                SiteLink(title: "Phone app", url: Links.releases, palette: palette) { Image(systemName: "smartphone") }
                SiteLink(title: "GitHub", url: Links.repo, palette: palette) {
                    PathShape.github.fill(style: FillStyle(eoFill: true)).frame(width: 13, height: 13)
                }
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .opacity(0.6)
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Links")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 26)
        .frame(width: 500)
        .foregroundStyle(palette.foreground)
        .tint(palette.alt)
        .toggleStyle(TrailingSwitchStyle(palette: palette))
        .background(WindowSurface(palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: WindowSurface.radius, style: .continuous))
        .keyboardNavigation(keyboard)
    }

    @ViewBuilder private func status(_ palette: Palette) -> some View {
        let state = model.state
        let phone = state?.connected == true ? state?.status : nil
        if let state {
            if state.connected {
                Label("\(state.phone ?? "Phone") is connected", systemImage: "iphone.radiowaves.left.and.right").font(.headline)
            } else if state.bluetooth != "on" {
                Label("Bluetooth is \(state.bluetooth)", systemImage: "exclamationmark.triangle").font(.headline)
            } else {
                Label("Looking for your phone…", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            }
        } else {
            Label("The background agent isn't running", systemImage: "moon.zzz").font(.headline)
        }

        // Unknown (knob centred, disabled) until the phone reports a state it can change; starting
        // is in-between too. Failed counts as off so it can be retried.
        HotspotSwitch(
            isOn: phone.flatMap { $0.hotspot == .on ? true : ($0.hotspot == .off || $0.hotspot == .failed) ? false : nil },
            enabled: phone?.controllable == true && phone?.hotspot != .starting,
            palette: palette
        ) { model.send($0 ? "enable" : "disable") }

        if let phone {
            if phone.hotspot == .failed {
                Text("The phone couldn't switch its hotspot. Try again, or check Tetherbug on the phone.").font(.caption).opacity(0.7)
            }
            if !phone.controllable {
                Text("Shizuku isn't ready on your phone, so it can't switch the hotspot. Open Tetherbug there.")
                    .font(.caption).opacity(0.7)
            }
        }
        // The rows stay put while the phone connects, as placeholders, so the card doesn't jump.
        HStack(spacing: 10) {
            Text("Network")
            Spacer()
            Text(phone?.ssid ?? "My Hotspot").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .redacted(reason: phone == nil ? .placeholder : [])
            // Lines the name up with the password, which has its buttons here.
            Color.clear.frame(width: PasswordRow.actionsWidth, height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue(phone?.ssid ?? "unknown")
        .accessibilityAddTraits(.isStaticText)
        PasswordRow(model: model, palette: palette, available: phone != nil)
        // One line: the phone's cellular signal (which limits the hotspot's speed), or what to do.
        Group {
            if let phone {
                Text("Cell signal \(phone.signal)/4")
            } else if state == nil {
                Text("Turn on “Run in the background” below to start it.")
            } else if state?.bluetooth == "unauthorized" {
                HStack(spacing: 4) {
                    Text("Allow Tetherbug under Privacy & Security → Bluetooth.")
                    SiteLink("Open settings →", url: Links.bluetoothSettings, palette: palette)
                }
            } else if state?.bluetooth == "on" {
                HStack(spacing: 4) {
                    Text("Make sure Tetherbug is running on your phone.")
                    SiteLink("How to pair →", url: Links.pairing, palette: palette)
                }
            } else {
                Text("Turn Bluetooth on to reach your phone.")
            }
        }
        .font(.caption)
        .opacity(0.7)
        .lineLimit(1)
    }
}

/// The hotspot password, hidden until asked for; Copy puts it on the clipboard.
/// A label as wide as its widest alternative, so switching between them doesn't move its neighbours.
struct SteadyLabel: View {
    let text: String
    let alternatives: [String]

    init(_ text: String, alternatives: [String]) {
        self.text = text
        self.alternatives = alternatives
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(alternatives, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct PasswordRow: View {
    @ObservedObject var model: AgentModel
    let palette: Palette
    /// False until the phone is connected: the row shows as a placeholder.
    var available = true
    @State private var shown = false
    /// Bumped on every copy; the label says "Copied!" until 5s after the latest one.
    @State private var copies = 0
    @State private var copied = false
    /// Fits "Hide" and "Copied!", so the password doesn't shift as the labels change.
    static let actionsWidth: CGFloat = 110

    private func toggleShown() {
        if !shown { model.fetchPassword() }
        shown.toggle()
    }

    private func copy() {
        model.fetchPassword()
        // Copy once the agent has replied.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let password = model.password else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
            copies += 1
            copied = true
            let copy = copies
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if copies == copy { copied = false } }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Password")
            Spacer()
            Group {
                // A word rather than dots, so nothing hints at the password's length.
                if shown {
                    Text(model.password ?? "…").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("Hidden").font(.system(.body, design: .monospaced)).italic().opacity(0.6)
                }
            }
            .redacted(reason: available ? [] : .placeholder)
                .accessibilityLabel(shown ? (model.password ?? "loading") : "hidden")
            HStack(spacing: 10) {
                Button(action: toggleShown) { SteadyLabel(shown ? "Hide" : "Show", alternatives: ["Show", "Hide"]) }
                    .buttonStyle(TextButtonStyle(palette: palette))
                    .keyboardFocusable(palette, radius: 4, action: toggleShown)
                Button(action: copy) { SteadyLabel(copied ? "Copied!" : "Copy", alternatives: ["Copy", "Copied!"]) }
                    .buttonStyle(TextButtonStyle(palette: palette))
                    .keyboardFocusable(palette, radius: 4, action: copy)
            }
            .frame(width: Self.actionsWidth, alignment: .leading)
            .disabled(!available)
            .opacity(available ? 1 : 0.4)
        }
        .onChange(of: available) { if !available { shown = false } }
    }
}

/// A borderless window that can still take keyboard focus and close from ⌘W / the close control.
final class AppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }

    // VoiceOver gets real window buttons in place of the drawn bubbles, which it doesn't see.
    private lazy var minimizeButton = WindowButton("Minimize", subrole: .minimizeButton, window: self) { [weak self] in self?.miniaturize(nil) }
    private lazy var closeButton = WindowButton("Close", subrole: .closeButton, window: self) { [weak self] in self?.close() }
    override func accessibilityChildren() -> [Any]? { [minimizeButton, closeButton] + (super.accessibilityChildren() ?? []) }
    override func accessibilityMinimizeButton() -> Any? { minimizeButton }
    override func accessibilityCloseButton() -> Any? { closeButton }
}

/// A window button for VoiceOver, placed over its drawn bubble (WindowControl reports the frame).
final class WindowButton: NSAccessibilityElement {
    /// SwiftUI frames of the drawn bubbles by label, in window coordinates with a top-left origin.
    static var frames: [String: CGRect] = [:]
    private let label: String
    private weak var window: NSWindow?
    private let press: () -> Void

    init(_ label: String, subrole: NSAccessibility.Subrole, window: NSWindow, press: @escaping () -> Void) {
        self.label = label
        self.window = window
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilitySubrole(subrole)
        setAccessibilityLabel(label)
        setAccessibilityParent(window)
    }

    override func accessibilityFrame() -> NSRect {
        guard let window, let content = window.contentView, let f = Self.frames[label] else { return .zero }
        return window.convertToScreen(NSRect(x: f.minX, y: content.bounds.height - f.maxY, width: f.width, height: f.height))
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = AgentModel()
    private var bluetooth: CBCentralManager?

    /// macOS never shows the windowless agent the Bluetooth prompt, so ask from the window: the agent
    /// is the same app and shares the grant. Only an active app may prompt.
    func applicationDidBecomeActive(_ notification: Notification) {
        // Coming back from System Settings, maybe with notifications switched on.
        model.checkNotifications()
        if bluetooth == nil, CBManager.authorization == .notDetermined { bluetooth = CBCentralManager(delegate: nil, queue: nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Content fills the whole window; the themed view draws its own close/minimise controls.
        // Borderless and transparent: the content draws the rounded, bevelled window body itself, and
        // the system shadow follows that shape.
        window = AppWindow(contentRect: .zero, styleMask: [.borderless, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tetherbug"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        NSApp.mainMenu = mainMenu()
        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The shadow is computed from the window's alpha, so redo it once the rounded body is drawn.
        DispatchQueue.main.async { self.window.invalidateShadow() }
    }

    /// Keeps ⌘W, ⌘M and ⌘Q working without the standard window buttons.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Quit Tetherbug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu!.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu!.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        menu.addItem(appItem)
        menu.addItem(windowItem)
        return menu
    }

    // Closing the window quits the app; the background agent keeps running on its own.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.stopSessionAgent() }
}

func runApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}
