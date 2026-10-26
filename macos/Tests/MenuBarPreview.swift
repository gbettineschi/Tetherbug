import AppKit

/// Interactive smoke test of the real native menu, with no Bluetooth or user preference changes.
@main
struct MenuBarPreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let preview = Preview()
        app.delegate = preview
        withExtendedLifetime(preview) { app.run() }
    }
}

private final class Preview: NSObject, NSApplicationDelegate {
    private let suite = "ie.xav.tetherbug.preview.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let control: HotspotControl
    private var state = AgentState()
    private var menu: MenuBarController!
    private var window: NSWindow!
    private let label = NSTextField(labelWithString: "")

    override init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "onNoWifi")
        control = HotspotControl(defaults: defaults)
        super.init()
        state.connected = true
        state.phone = "Alex's phone"
        state.bluetooth = "on"
        state.wifiOffline = true
        report(on: false)
        menu = MenuBarController(
            onToggle: { [weak self] in self?.toggle() },
            onAutomatic: { [weak self] on in self?.control.automatic = on; self?.publish() },
            onSettings: { print("PREVIEW Settings requested"); fflush(stdout) },
            onQuit: { NSApp.terminate(nil) }
        )
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tetherbug Menu Preview"
        let note = NSTextField(labelWithString: "Simulated phone only. No Bluetooth commands.")
        let toggle = NSButton(title: "Click hotspot icon", target: self, action: #selector(clickIcon))
        let show = NSButton(title: "Show hotspot menu", target: self, action: #selector(showMenu))
        let scenario = NSPopUpButton()
        scenario.addItems(withTitles: ["Connected phone", "Long phone name", "Unnamed phone", "Disconnected", "Shizuku not ready", "Hotspot starting", "Hotspot failed"])
        scenario.target = self
        scenario.action = #selector(changeScenario(_:))
        let stack = NSStackView(views: [note, label, toggle, show, scenario])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        publish()
        print("PREVIEW ready: simulated phone only; click the hotspot icon for the menu.")
        fflush(stdout)
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
    func applicationWillTerminate(_ notification: Notification) { defaults.removePersistentDomain(forName: suite) }

    @objc private func clickIcon() { showMenu() }
    @objc private func showMenu() {
        let view = window.contentView!
        menu.menu.popUp(positioning: nil, at: NSPoint(x: 30, y: view.bounds.maxY - 15), in: view)
    }

    @objc private func changeScenario(_ sender: NSPopUpButton) {
        state.connected = sender.indexOfSelectedItem != 3
        state.phone = sender.indexOfSelectedItem == 1 ? "A very long custom phone name that should remain available in its tooltip" :
            sender.indexOfSelectedItem == 2 ? nil : "Alex's phone"
        report(on: false)
        state.status?.controllable = sender.indexOfSelectedItem != 4
        if sender.indexOfSelectedItem == 5 { state.status?.hotspot = .starting }
        if sender.indexOfSelectedItem == 6 { state.status?.hotspot = .failed }
        publish()
    }

    private func toggle() {
        guard let on = control.toggle(state) else { return }
        publish()
        control.writeCompleted(error: nil) // simulate the one Bluetooth write callback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.report(on: on)
            if let self { self.control.refresh(self.state, receivedStatus: true); self.publish() }
        }
    }

    private func report(on: Bool) {
        state.status = PhoneStatus(Data([3, on ? 2 : 0, 83, 4, 1, 0, 0] + Array("Preview hotspot".utf8)))!
    }

    private func publish() {
        state.automatic = control.automatic
        state.automaticPausedUntil = control.pausedUntil
        state.requestPending = control.isPending
        state.requestError = control.error
        menu?.update(state)
        label.stringValue = "Hotspot \(state.status?.hotspot.rawValue ?? "unknown") · Auto \(control.automatic ? "on" : "off") · \(control.pausedUntil != nil ? "paused for 15 minutes" : "not paused")"
        print("PREVIEW hotspot=\(state.status?.hotspot.rawValue ?? "unknown") auto=\(control.automatic) paused=\(control.pausedUntil != nil) pending=\(control.isPending)")
        fflush(stdout)
    }
}
