import AppKit
import Foundation

// The tests never request notification permission (normally implemented by the CLI entry point).
func notificationPermissionGranted() -> Bool { false }

func runMenuBarTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    test("native menu keeps the persisted pause beside automatic mode without a Resume item") {
        var mode: Bool?
        let menu = MenuBarController(onToggle: {}, onAutomatic: { mode = $0 }, onSettings: {}, onQuit: {})
        var state = phoneState(.off)
        state.automatic = true
        state.automaticPausedUntil = now.addingTimeInterval(900)
        menu.update(state)
        let auto = menu.menu.items.first { $0.action == #selector(MenuBarController.changeAutomatic(_:)) }!
        expect(auto.state == .on, "Auto checkbox follows snapshot")
        expect(auto.attributedTitle?.string.contains("Paused until") == true, "expiry is on the Auto row")
        expect(!menu.menu.items.contains { $0 !== auto && $0.title.localizedCaseInsensitiveContains("paused until") }, "no standalone pause row")
        expect(!menu.menu.items.contains { $0.title.localizedCaseInsensitiveContains("resume") }, "manual On is the resume control")
        menu.menu.performActionForItem(at: menu.menu.index(of: auto))
        expect(mode == false, "Auto action requests disable")
    }

    test("Finder reopening the accessory agent routes to the regular settings window") {
        var opens = 0
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onSettings: { opens += 1 }, onQuit: {})
        expect(!menu.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "agent has no window to reopen itself")
        expect(opens == 1, "forward reopen to Settings exactly once")
    }

    test("concurrent agent starts have one lifetime owner and release ownership on exit") {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        final class Results: @unchecked Sendable {
            let gate = NSLock()
            var owners: [AgentLock] = []
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if let lease = AgentLock(path: path) {
                results.gate.lock()
                results.owners.append(lease)
                results.gate.unlock()
            }
        }
        expect(results.owners.count == 1, "one owner across simultaneous starts")
        expect(AgentLock(path: path) == nil, "owner keeps its lease for its lifetime")
        results.owners.removeAll()
        expect(AgentLock(path: path) != nil, "a later start acquires the released lease")
    }

    test("status item opens its menu and only the ready hotspot switch requests a change") {
        var requests = 0
        let menu = MenuBarController(onToggle: { requests += 1 }, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        expect(menu.item.menu === menu.menu, "native dropdown handles ordinary and secondary clicks")
        guard let toggle = menuSwitch(menu) else { expect(false, "menu contains the native hotspot switch"); return }
        menu.update(AgentState())
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        expect(requests == 0, "no command while disconnected")
        var state = phoneState(.on)
        state.requestPending = true
        menu.update(state)
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        expect(requests == 0, "no duplicate command while pending")
        state.requestPending = false
        menu.update(state)
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        expect(requests == 1, "available hotspot switch reaches agent once")
    }

    test("failed request remains visible alongside actual phone state") {
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        var state = phoneState(.on)
        state.requestError = "Bluetooth write failed"
        menu.update(state)
        expect(menuSwitch(menu)?.state == .on, "reported On retained")
        expect(menu.menu.items.contains { $0.title == "Bluetooth write failed" }, "error is visible")
        expect(menu.item.button?.toolTip?.contains("Bluetooth write failed") == true, "tooltip explains failure")
    }

    test("pending starting failure and disconnection retain the last confirmed menu-bar image") {
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        menu.update(phoneState(.on))
        let confirmedOn = menu.item.button?.image?.tiffRepresentation
        var pending = phoneState(.on)
        pending.requestPending = true
        for state in [pending, phoneState(.starting), phoneState(.failed), AgentState()] {
            menu.update(state)
            expect(menu.item.button?.image?.tiffRepresentation == confirmedOn, "transient states cannot replace the On icon")
            expect(menu.item.button?.appearsDisabled == false, "menu stays available")
        }
        menu.update(phoneState(.off))
        expect(menu.item.button?.image?.tiffRepresentation != confirmedOn, "confirmed Off changes the icon")
        let confirmedOff = menu.item.button?.image?.tiffRepresentation
        var starting = phoneState(.starting)
        starting.requestPending = true
        menu.update(starting)
        expect(menu.item.button?.image?.tiffRepresentation == confirmedOff, "pending On keeps the Off icon")
    }

    test("open menu keeps its header alive and binds the latest phone name and status") {
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        let originalMenu = menu.menu
        let originalHeader = menu.menu.items.first?.view
        var state = phoneState(.off)
        state.phone = "A phone with a custom name"
        menu.update(state)
        expect(menu.menu === originalMenu, "state updates do not replace the open menu")
        expect(originalHeader != nil && menu.menu.items.first?.view === originalHeader, "existing controls receive updates")
        expect(menuLabels(menu).contains("A phone with a custom name"), "display the reported device name")
        expect(menuSwitch(menu)?.state == .off, "actual phone state reaches the switch")
        state.status = phoneState(.on).status
        menu.update(state)
        expect(menuSwitch(menu)?.state == .on, "same switch receives the confirmation")
        state.phone = nil
        menu.update(state)
        expect(menuLabels(menu).contains("Connected phone"), "an unnamed phone must not inherit an old device name")
        menu.update(AgentState())
        expect(menuLabels(menu).contains { $0.localizedCaseInsensitiveContains("not connected") }, "loss of the phone is explained in the open menu")
        expect(menuSwitch(menu)?.state == .on && menuSwitch(menu)?.isEnabled == false, "last confirmation remains visible but unavailable")
    }

    test("hotspot switch rejects unknown starting and Shizuku-unavailable snapshots") {
        var requests = 0
        let menu = MenuBarController(onToggle: { requests += 1 }, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        guard let toggle = menuSwitch(menu) else { expect(false, "native switch is present"); return }
        for state in [AgentState(), phoneState(.starting), phoneState(.off, controllable: false)] {
            menu.update(state)
            expect(!toggle.isEnabled, "unavailable snapshot disables the switch")
            _ = toggle.sendAction(toggle.action, to: toggle.target)
        }
        expect(requests == 0, "stale control actions cannot issue a command")
    }

    test("manual On from the menu clears the real automatic pause") {
        let (control, _) = environment()
        _ = control.toggle(phoneState(.on), now: now)
        control.writeCompleted(error: nil)
        control.refresh(phoneState(.off), now: now, receivedStatus: true)
        var state = phoneState(.off)
        state.automatic = true
        state.automaticPausedUntil = control.pausedUntil
        let menu = MenuBarController(onToggle: { _ = control.toggle(state, now: now.addingTimeInterval(5)) }, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        menu.update(state)
        guard let toggle = menuSwitch(menu) else { expect(false, "native switch is present"); return }
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        expect(control.pausedUntil == nil && control.isPending, "manual On cancels the pause and requests the hotspot")
    }

    test("a failed hotspot presents an Off retry switch while keeping the confirmed icon") {
        let (control, _) = environment(automatic: false)
        let failed = phoneState(.failed)
        var requested: Bool?
        let menu = MenuBarController(onToggle: { requested = control.toggle(failed, now: now) }, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        menu.update(phoneState(.on))
        let lastIcon = menu.item.button?.image?.tiffRepresentation
        menu.update(failed)
        guard let toggle = menuSwitch(menu) else { expect(false, "native switch is present"); return }
        expect(toggle.state == .off && toggle.isEnabled, "the visible switch offers the On retry the policy will send")
        expect(menuLabels(menu).contains { $0.localizedCaseInsensitiveContains("retry") }, "failure explains the retry action")
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        expect(requested == true, "retry requests On")
        expect(menu.item.button?.image?.tiffRepresentation == lastIcon, "failure cannot replace the last confirmed status icon")
    }

    test("agent maintenance processes an unconfirmed request while the menu tracks") {
        let (control, _) = environment(automatic: false)
        _ = control.toggle(phoneState(.off), now: now)
        let timer = scheduleAgentMaintenance { control.refresh(phoneState(.off), now: now.addingTimeInterval(16)) }
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(1.4)
        while control.error == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        expect(control.error != nil && control.needsReconnect, "15-second request timeout must request recovery without waiting for the dropdown to close")
    }

    test("new client decodes old agent snapshots") {
        let data = Data(#"{"bluetooth":"on","connected":false,"wifiOffline":false}"#.utf8)
        let state = try? JSONDecoder().decode(AgentState.self, from: data)
        expect(state != nil && state?.automatic == nil && state?.requestPending == nil, "optional fields preserve compatibility")
    }

    test("settings window follows agent Auto changes without overwriting shared preferences") {
        let (_, defaults) = environment(automatic: true)
        let connected = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        var deliver: ((AgentState) -> Bool)?
        let model = AgentModel(defaults: defaults, watch: { handler in
            deliver = handler
            connected.signal()
            finish.wait()
            return true
        })
        expect(connected.wait(timeout: .now() + 2) == .success, "watcher starts")
        var snapshot = phoneState(.off)
        snapshot.automatic = false
        _ = deliver?(snapshot)
        let deadline = Date().addingTimeInterval(2)
        while model.state == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(model.onNoWifi == false, "checkbox follows current agent snapshot")
        expect(defaults.bool(forKey: "onNoWifi"), "receiving a snapshot must not write stale values back")
        finish.signal()
    }

    test("opening settings restores a missing helper even when login registration is enabled") {
        var launches = 0
        var child: Process?
        let model = AgentModel(watch: { _ in false }, launchAgent: {
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            child = process
            return process
        })
        model.loginItem = .enabled
        defer { model.closeSettings(); child?.terminate(); child?.waitUntilExit() }
        let deadline = Date().addingTimeInterval(2)
        while launches == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(launches == 1, "enabled registration cannot suppress missing-helper recovery")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(launches == 1, "a live helper is not launched twice")
        model.closeSettings()
        expect(child?.isRunning == true, "closing settings keeps the menu-bar helper alive")
    }

    test("explicit Quit stops an owned helper and suppresses recovery when the socket is unavailable") {
        var launches = 0
        var child: Process?
        var commands: [String] = []
        let model = AgentModel(watch: { _ in false }, launchAgent: {
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            child = process
            return process
        }, request: { command in commands.append(command); return false })
        defer { if child?.isRunning == true { child?.terminate(); child?.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(2)
        while launches == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        var finished = false
        model.quit { finished = true }
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(finished && child?.isRunning == false, "explicit Quit completes with the owned helper stopped")
        expect(commands == ["quit"], "Quit requests a coordinated agent shutdown")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(launches == 1, "a quit app must not recover its helper")
    }
}

private func menuViews(_ menu: MenuBarController) -> [NSView] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    return menu.menu.items.compactMap(\.view).flatMap(descendants)
}

private func menuSwitch(_ menu: MenuBarController) -> HotspotSwitch? { menuViews(menu).compactMap { $0 as? HotspotSwitch }.first }
private func menuLabels(_ menu: MenuBarController) -> [String] { menuViews(menu).compactMap { ($0 as? NSTextField)?.stringValue } }
