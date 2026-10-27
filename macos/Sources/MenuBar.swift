import AppKit

/// The existing agent owns one native dropdown; updates also reach a menu already open.
final class MenuBarController: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let hotspot = HotspotMenuView()
    private let hotspotItem = NSMenuItem()
    private let automaticItem = NSMenuItem()
    private let durationItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private var state = AgentState()
    private var confirmedOn = false
    private var displayedSymbol: String?
    private var phoneName: String?
    private let onToggle: () -> Void
    private let onAutomatic: (Bool) -> Void
    private let onPauseAutomatic: (AutomaticPauseDuration) -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(onToggle: @escaping () -> Void, onAutomatic: @escaping (Bool) -> Void,
         onPauseAutomatic: @escaping (AutomaticPauseDuration) -> Void = { _ in },
         onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onAutomatic = onAutomatic
        self.onPauseAutomatic = onPauseAutomatic
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()
        menu.autoenablesItems = false
        menu.minimumWidth = 328
        hotspotItem.view = hotspot
        hotspotItem.title = "Mobile Hotspot"
        hotspotItem.target = self
        hotspotItem.action = #selector(changeHotspot(_:))
        hotspot.toggle.target = self
        hotspot.toggle.action = #selector(changeHotspot(_:))
        hotspot.onActivate = { [weak self] in self?.changeHotspot(nil) }
        menu.addItem(hotspotItem)
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)
        menu.addItem(.separator())
        automaticItem.target = self
        automaticItem.action = #selector(changeAutomatic(_:))
        // AppKit collapses an empty state column; keep its space without drawing an Off mark.
        if let checkmark = automaticItem.onStateImage {
            automaticItem.offStateImage = NSImage(size: checkmark.size, flipped: false) { _ in true }
        }
        menu.addItem(automaticItem)
        durationItem.title = "Turn off automatic mode for…"
        let durations = NSMenu()
        durations.autoenablesItems = false
        for duration in AutomaticPauseDuration.allCases {
            let choice = NSMenuItem(title: duration.title, action: #selector(pauseAutomatic(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = duration.rawValue
            durations.addItem(choice)
        }
        durationItem.submenu = durations
        menu.addItem(durationItem)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings(_:)), key: ","))
        menu.addItem(action("Quit Tetherbug", #selector(quit(_:)), key: "q"))
        item.menu = menu
        update(state)
    }

    deinit { NSStatusBar.system.removeStatusItem(item) }

    private var canToggle: Bool {
        state.connected && state.status?.controllable == true && state.status?.hotspot != .starting &&
            state.status != nil && state.requestPending != true && state.stopping != true
    }

    private var switchOn: Bool { state.connected && state.status?.hotspot == .failed ? false : confirmedOn }

    func update(_ state: AgentState) {
        self.state = state
        if state.connected {
            let name = state.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
            phoneName = name?.isEmpty == false ? name : nil
        }
        if state.connected, let reported = state.status?.hotspot {
            if reported == .on { confirmedOn = true }
            else if reported == .off { confirmedOn = false }
        }
        let description: String
        if state.stopping == true { description = "Quitting Tetherbug…" }
        else if !state.connected { description = "Phone not connected" }
        else if state.status?.controllable == false { description = "Shizuku is not ready" }
        else if state.requestPending == true { description = "Waiting for the phone…" }
        else if state.status?.hotspot == .starting { description = "Starting hotspot…" }
        else if state.status?.hotspot == .failed { description = "Hotspot failed — turn on to retry" }
        else { description = state.status.map { "Hotspot \($0.hotspot.rawValue)" } ?? "Waiting for phone status…" }

        let symbol = confirmedOn ? "personalhotspot" : "personalhotspot.slash"
        if displayedSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mobile Hotspot")
            image?.isTemplate = true
            item.button?.image = image
            displayedSymbol = symbol
        }
        item.button?.appearsDisabled = false
        item.button?.setAccessibilityLabel("Tetherbug: \(description)")
        let automaticActive = state.automatic == true && !state.automaticSuspended
        var details = [description, automaticActive ? "Automatic mode on" : "Automatic mode off"]
        if state.automatic == true, let expiry = state.automaticPausedUntil {
            details.append("Automatic mode turned off until \(Self.time(expiry))")
        }
        if let error = state.requestError { details.append(error) }
        item.button?.toolTip = details.joined(separator: "\n")

        let ready = state.connected && state.status != nil && state.status?.controllable == true &&
            state.requestPending != true && state.status?.hotspot != .starting &&
            state.status?.hotspot != .failed && state.stopping != true
        hotspot.update(on: switchOn, enabled: canToggle,
                       detail: ready ? (phoneName ?? "Connected phone") : description, phoneName: phoneName)
        hotspotItem.isEnabled = canToggle
        errorItem.title = state.requestError ?? ""
        errorItem.toolTip = state.requestError
        errorItem.isHidden = state.requestError == nil
        automaticItem.title = "Automatic Mode"
        automaticItem.state = automaticActive ? .on : .off
        let automaticAvailable = state.stopping != true
        automaticItem.isEnabled = automaticAvailable
        durationItem.isEnabled = automaticAvailable
        durationItem.submenu?.items.forEach { $0.isEnabled = automaticAvailable }
        let title = NSMutableAttributedString(string: "Automatic Mode", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if state.automatic == true, let expiry = state.automaticPausedUntil {
            title.append(NSAttributedString(string: "    Turned off until \(Self.time(expiry))", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        automaticItem.attributedTitle = title
    }

    @objc private func changeHotspot(_ sender: Any?) {
        // Restore the switch's optimistic change: the phone remains the source of truth.
        hotspot.toggle.state = switchOn ? .on : .off
        guard canToggle else { return }
        onToggle()
    }

    func showMenu(at view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onSettings()
        return false
    }

    @objc func changeAutomatic(_ sender: Any?) {
        guard state.stopping != true else { return }
        onAutomatic(state.automatic != true || state.automaticSuspended)
    }
    @objc func pauseAutomatic(_ sender: NSMenuItem) {
        guard state.stopping != true,
              let raw = sender.representedObject as? String,
              let duration = AutomaticPauseDuration(rawValue: raw) else { return }
        onPauseAutomatic(duration)
    }
    @objc private func openSettings(_ sender: Any?) { onSettings() }
    @objc private func quit(_ sender: Any?) { onQuit() }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private static func time(_ date: Date) -> String {
        let format = DateFormatter()
        format.timeStyle = .short
        return format.string(from: date)
    }
}

/// Standard button interaction and accessibility, with an On tint that survives inactive menus.
final class HotspotSwitch: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 54, height: 24) }
    override var focusRingMaskBounds: NSRect { bounds }

    init() {
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        title = ""
        isBordered = false
        focusRingType = .exterior
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = track.height / 2
        let on = state == .on
        let color: NSColor = on ? .systemBlue : .quaternaryLabelColor
        (isEnabled ? color : color.withAlphaComponent(color.alphaComponent * 0.45)).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let diameter = track.height - 4
        let knob = NSRect(x: on ? track.maxX - diameter - 2 : track.minX + 2,
                          y: track.minY + 2, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.8).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    func updateHelp(_ text: String) { setAccessibilityHelp(text) }
}

private final class HotspotMenuView: NSView {
    let toggle = HotspotSwitch()
    var onActivate: (() -> Void)?
    private let badge = NSBox()
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "Mobile Hotspot")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 328, height: 74))
        autoresizingMask = [.width]
        badge.boxType = .custom
        badge.borderWidth = 0
        badge.cornerRadius = 16
        badge.contentViewMargins = .zero
        symbol.image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.imageScaling = .scaleProportionallyDown
        badge.contentView?.addSubview(symbol)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        for view in [badge, labels, toggle] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 32), badge.heightAnchor.constraint(equalToConstant: 32),
            symbol.centerXAnchor.constraint(equalTo: badge.contentView!.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: badge.contentView!.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 18), symbol.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 16),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toggle.setAccessibilityLabel("Mobile Hotspot")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(on: Bool, enabled: Bool, detail text: String, phoneName: String?) {
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        toggle.updateHelp(text)
        badge.fillColor = on ? .controlAccentColor : .quaternaryLabelColor
        symbol.contentTintColor = on ? .white : .secondaryLabelColor
        detail.stringValue = text
        detail.toolTip = phoneName.map { $0 == text ? text : "\($0) — \(text)" } ?? text
        toolTip = detail.toolTip
    }

    override func mouseUp(with event: NSEvent) {
        guard toggle.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

}
