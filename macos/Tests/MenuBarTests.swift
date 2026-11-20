import ServiceManagement
import AppKit
import Foundation
import CoreServices

// The tests never request notification permission (normally implemented by the CLI entry point).
func notificationPermissionGranted() -> Bool { false }

func runMenuBarTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    test("native command menu width stays stable when the Auto checkmark changes") {
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onSettings: {}, onQuit: {})
        // Measure command rows without the wide custom header masking native gutter changes.
        menu.menu.removeItem(at: 0)
        menu.menu.minimumWidth = 0
        var state = phoneState()
        state.automatic = false
        menu.update(state)
        menu.menu.update()
        let offWidth = menu.menu.size.width
        state.automatic = true
        menu.update(state)
        menu.menu.update()
        let onWidth = menu.menu.size.width
        state.automatic = false
        menu.update(state)
        menu.menu.update()
        expect(offWidth == onWidth, "adding the checkmark must not change the measured menu width")
        expect(menu.menu.size.width == onWidth, "removing the checkmark must preserve the reserved space")
    }

    test("native menu keeps the persisted pause beside automatic mode without a Resume item") {
        var mode: Bool?
        let menu = MenuBarController(onToggle: {}, onAutomatic: { mode = $0 }, onSettings: {}, onQuit: {})
        var state = phoneState(.off)
        state.automatic = true
        state.automaticPausedUntil = now.addingTimeInterval(900)
        menu.update(state)
        let auto = menu.menu.items.first { $0.action == #selector(MenuBarController.changeAutomatic(_:)) }!
        expect(auto.state == .off, "suspended Auto has no checkmark")
        expect(auto.attributedTitle?.string.contains("Turned off until") == true, "expiry is on the Auto row")
        expect(!menu.menu.items.contains { $0 !== auto && $0.title.localizedCaseInsensitiveContains("paused until") }, "no standalone pause row")
        expect(!menu.menu.items.contains { $0.title.localizedCaseInsensitiveContains("resume") }, "manual On is the resume control")
        menu.menu.performActionForItem(at: menu.menu.index(of: auto))
        expect(mode == true, "suspended Auto action requests resume")
    }

    test("duration submenu offers every requested duration and routes each selection") {
        var selected: [AutomaticPauseDuration] = []
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in }, onPauseAutomatic: { selected.append($0) }, onSettings: {}, onQuit: {})
        var state = phoneState()
        state.automatic = true
        menu.update(state)
        guard let item = menu.menu.items.first(where: { $0.title == "Turn off automatic mode for…" }), let submenu = item.submenu else {
            expect(false, "native duration submenu exists"); return
        }
        expect(submenu.items.map(\.title) == ["15 minutes", "30 minutes", "1 hour", "2 hours", "3 hours", "Today", "Indefinitely"], "timed and indefinite choices are offered")
        for index in submenu.items.indices { submenu.performActionForItem(at: index) }
        expect(selected == AutomaticPauseDuration.allCases, "every native menu action reaches the selected policy")
    }

    test("Automatic Mode menu actions turn off without an expiry and resume the real policy") {
        let (control, _) = environment()
        let menu = MenuBarController(onToggle: {}, onAutomatic: { control.setAutomaticActive($0) }, onSettings: {}, onQuit: {})
        var state = phoneState()
        state.automatic = true
        menu.update(state)
        let auto = menu.menu.items.first { $0.action == #selector(MenuBarController.changeAutomatic(_:)) }!
        expect(auto.state == .on, "active automatic mode is checked")
        menu.menu.performActionForItem(at: menu.menu.index(of: auto))
        expect(!control.automatic && control.pausedUntil == nil, "click turns mode off without expiry")
        state.automatic = control.automatic
        state.automaticPausedUntil = control.pausedUntil
        menu.update(state)
        expect(auto.state == .off && auto.isEnabled, "Off item remains available to resume")
        expect(auto.attributedTitle?.string == "Automatic Mode", "Off has no until label")
        menu.menu.performActionForItem(at: menu.menu.index(of: auto))
        expect(control.pausedUntil == nil && control.automatic, "second click re-enables automatic mode")
    }

    test("disabled automatic mode hides expiry and both controls remain available") {
        var actions = 0
        let menu = MenuBarController(onToggle: {}, onAutomatic: { _ in actions += 1 }, onPauseAutomatic: { _ in actions += 1 }, onSettings: {}, onQuit: {})
        var state = phoneState()
        state.automatic = false
        menu.update(state)
        let auto = menu.menu.items.first { $0.action == #selector(MenuBarController.changeAutomatic(_:)) }!
        let durations = menu.menu.items.first { $0.submenu != nil }!
        expect(auto.state == .off && auto.attributedTitle?.string == "Automatic Mode", "Off has no checkmark or expiry text")
        expect(auto.isEnabled && durations.isEnabled, "suspended choices remain usable")
        state.automatic = false
        menu.update(state)
        expect(auto.isEnabled && durations.isEnabled, "automatic controls stay available when mode is off")
        expect(durations.submenu!.items.allSatisfy { $0.isEnabled }, "all durations stay available")
        menu.changeAutomatic(nil)
        menu.pauseAutomatic(durations.submenu!.items[0])
        expect(actions == 2, "both controls work when automatic mode is off")
        state.automatic = true
        state.stopping = true
        menu.update(state)
        expect(!auto.isEnabled && !durations.isEnabled, "quitting also disables both rows")
        menu.changeAutomatic(nil)
        menu.pauseAutomatic(durations.submenu!.items[0])
        expect(actions == 2, "quitting rejects further actions")
    }

    test("clicking unchecked Automatic Mode resumes from Settings Off") {
        let (control, _) = environment(automatic: false)
        let menu = MenuBarController(onToggle: {}, onAutomatic: { control.setAutomaticActive($0) }, onSettings: {}, onQuit: {})
        var state = phoneState()
        state.automatic = false
        menu.update(state)
        let auto = menu.menu.items.first { $0.action == #selector(MenuBarController.changeAutomatic(_:)) }!
        expect(auto.state == .off, "disabled automatic mode is unchecked")
        menu.menu.performActionForItem(at: menu.menu.index(of: auto))
        expect(control.automatic && control.shouldAutomaticallyEnable(state, now: now), "menu click resumes even from Settings Off")
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

    test("opening settings starts a session helper when launch at login is off") {
        var launches = 0
        var loginOperations = 0
        var child: Process?
        let model = AgentModel(watch: { _ in false }, launchAgent: {
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            child = process
            return process
        }, loginServiceStatus: { .notRegistered }, unregisterLoginService: { completion in
            loginOperations += 1
            completion(nil)
        }, registerLoginService: {}, isFullWake: { true })
        defer { model.closeSettings(); child?.terminate(); child?.waitUntilExit() }
        let deadline = Date().addingTimeInterval(2)
        while launches == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(launches == 1, "manual launch starts the helper with launch at login off")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(launches == 1, "a live helper is not launched twice")
        expect(loginOperations == 0, "opening with login disabled preserves that setting")
        model.closeSettings()
        expect(child?.isRunning == true, "closing settings keeps the menu-bar helper alive")
    }

    test("the login service takes the lease only after a session worker releases it") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var oldWorker = AgentLock(path: file.path)
        expect(oldWorker != nil, "session worker obtained the original lease")
        var requests = 0
        let declined = AgentLock.acquire(path: file.path, handover: { requests += 1; return .declined })
        expect(declined == nil, "another managed worker can refuse the handover")
        let newWorker = AgentLock.acquire(path: file.path, handover: {
            requests += 1
            oldWorker = nil
            return .accepted
        })
        expect(newWorker != nil && requests == 2, "registered worker inherits a released lease")
        withExtendedLifetime(newWorker) {
            expect(AgentLock(path: file.path) == nil, "the successor exclusively owns the lease")
        }
    }

    test("registered worker waits for a starting session worker's socket") {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var oldWorker = AgentLock(path: file.path)
        expect(oldWorker != nil, "session worker already holds the lock")
        var requests = 0
        let newWorker = AgentLock.acquire(path: file.path, handover: {
            requests += 1
            if requests == 1 { return .unavailable }
            oldWorker = nil
            return .accepted
        })
        expect(newWorker != nil && requests == 2, "retry after the socket becomes available")
    }

    test("enabled main-app login starts one session worker without re-registering on an update") {
        var launches = 0; var registrations = 0; var removals = 0; var child: Process?
        let model = AgentModel(watch: { _ in false }, launchAgent: {
            launches += 1
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
            try p.run(); child = p; return p
        }, loginServiceStatus: { .enabled }, legacyLoginServiceStatus: { .notRegistered },
            unregisterLoginService: { _ in removals += 1 }, registerLoginService: { registrations += 1 }, isFullWake: { true })
        defer { model.closeSettings(); if child?.isRunning == true { child?.terminate(); child?.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(2)
        while launches == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(launches == 1 && registrations == 0 && removals == 0, "a changed executable needs no LaunchAgent registration or kickstart")
        model.closeSettings()
        expect(child?.isRunning == true, "closing Settings retains the independent worker")
    }
    test("enabled legacy agent migrates once to native main-app login after removal completes") {
        var finished: ((Error?) -> Void)?; var registrations = 0; var legacy = SMAppService.Status.enabled
        let model = AgentModel(watch: { _ in false }, launchAgent: { Process() },
            loginServiceStatus: { registrations > 0 ? .enabled : .notRegistered }, legacyLoginServiceStatus: { legacy },
            unregisterLoginService: { finished = $0 }, registerLoginService: { registrations += 1 }, isFullWake: { true })
        defer { model.closeSettings() }
        let deadline = Date().addingTimeInterval(2)
        while finished == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(finished != nil && registrations == 0 && model.loginMigrationInFlight, "preserve removal ownership before enabling the native item")
        legacy = .notRegistered; finished?(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(registrations == 1 && model.loginItem == .enabled && !model.loginMigrationInFlight, "one migration preserves enabled login intent")
    }
    test("legacy login that was off or blocked never enables native login automatically") {
        for legacy in [SMAppService.Status.notRegistered, .requiresApproval] {
            var registrations = 0; var removals = 0
            let model = AgentModel(watch: { _ in false }, launchAgent: { Process() },
                loginServiceStatus: { .notRegistered }, legacyLoginServiceStatus: { legacy },
                unregisterLoginService: { _ in removals += 1 }, registerLoginService: { registrations += 1 }, isFullWake: { true })
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            expect(registrations == 0 && removals == 0, "native login preserves the user's disabled or blocked state")
            model.closeSettings()
        }
    }
    test("closing Settings waits for migration and a replacement worker serving status") {
        var finished: ((Error?) -> Void)?; var registrations = 0; var closed = false; var launches = 0
        var watcher: ((AgentState) -> Bool)?; var child: Process?
        let model = AgentModel(watch: { watcher = $0; return false }, launchAgent: {
            launches += 1
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
            try p.run(); child = p; return p
        }, loginServiceStatus: { .notRegistered }, legacyLoginServiceStatus: { .enabled },
            unregisterLoginService: { finished = $0 }, registerLoginService: { registrations += 1 }, isFullWake: { true })
        defer { model.closeSettings(); if child?.isRunning == true { child?.terminate(); child?.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(2)
        while finished == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(model.finishRegistrationBeforeClosing { closed = $0 } && !closed, "closing waits for native migration")
        finished?(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(registrations == 1 && launches == 1 && !closed, "native main-app registration does not start the replacement worker itself")
        _ = watcher?(phoneState(.off))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(!closed, "a stale legacy snapshot does not prove the new worker is ready")
        var fresh = phoneState(.off); fresh.workerPID = child?.processIdentifier
        _ = watcher?(fresh); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(closed && child?.isRunning == true, "close only after a new worker serves status")
    }
    test("Quit settles migration then stops the session worker while preserving future login") {
        var finished: ((Error?) -> Void)?; var registered = false; var requests = 0; var exited = false
        let model = AgentModel(watch: { _ in false }, launchAgent: { Process() }, request: { command in
            if command == "quit" && registered { requests += 1; return true }; return false
        }, loginServiceStatus: { .notRegistered }, legacyLoginServiceStatus: { .enabled },
            unregisterLoginService: { finished = $0 }, registerLoginService: { registered = true }, isFullWake: { true })
        defer { model.closeSettings() }
        let deadline = Date().addingTimeInterval(2)
        while finished == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        model.quit { exited = true }
        expect(!exited, "wait for the native removal acknowledgement")
        finished?(nil)
        while !exited && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(exited && registered && requests == 1, "Quit completes without disabling future login")
    }
    test("migration defers across DarkWake and respects revoked consent") {
        var allowed = true; var status = SMAppService.Status.enabled; var registrations = 0
        var finished: ((Error?) -> Void)?; var completed = 0
        let registration = LoginRegistration(status: { status }, allowed: { allowed },
            unregister: { finished = $0 }, register: { registrations += 1 })
        expect(registration.begin { _ in completed += 1 }, "begin authorized migration")
        allowed = false; finished?(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(registration.inFlight && registrations == 0, "no registration in DarkWake")
        allowed = true; status = .requiresApproval; registration.resume()
        expect(registrations == 0 && completed == 1 && !registration.inFlight, "revoked approval remains revoked")
    }
    test("cancelled migration owns native removal until its callback") {
        var finished: ((Error?) -> Void)?; var removals = 0; var settled = 0
        let registration = LoginRegistration(status: { .enabled }, allowed: { true },
            unregister: { removals += 1; finished = $0 }, register: {})
        _ = registration.begin { _ in settled += 1 }; registration.cancel()
        expect(registration.inFlight && !registration.begin { _ in } && removals == 1, "no overlapping removals")
        finished?(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(!registration.inFlight && settled == 1, "cancelled work still resolves its waiter")
    }
    test("an explicit toggle cannot bypass outstanding legacy migration") {
        var finished: ((Error?) -> Void)?; var registrations = 0
        let model = AgentModel(watch: { _ in false }, launchAgent: { Process() }, loginServiceStatus: { .notRegistered },
            legacyLoginServiceStatus: { .enabled }, unregisterLoginService: { finished = $0 },
            registerLoginService: { registrations += 1 }, isFullWake: { true })
        defer { model.closeSettings() }
        let deadline = Date().addingTimeInterval(2)
        while finished == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        model.setLoginItem(true)
        expect(registrations == 0, "the UI cannot overlap native registration changes")
        finished?(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(registrations == 1, "only the acknowledged migration enables login")
    }
    test("worker launch errors are visible and bounded until explicit Retry") {
        var attempts = 0
        let model = AgentModel(watch: { _ in false }, launchAgent: {
            attempts += 1; throw NSError(domain: "Test.Launch", code: 1)
        }, loginServiceStatus: { .enabled }, isFullWake: { true })
        defer { model.closeSettings() }
        let deadline = Date().addingTimeInterval(2)
        while attempts == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(attempts == 1 && model.loginServiceUnavailable && model.loginError != nil, "native login status does not conceal a worker launch failure")
        model.retryLoginService()
        expect(attempts == 2, "explicit Retry attempts the worker again")
    }
    test("a worker that exits before serving status cannot cause an endless restart loop") {
        var launches = 0; var uptime: TimeInterval = 10
        let model = AgentModel(watch: { _ in false }, launchAgent: { launches += 1; return Process() },
            loginServiceStatus: { .enabled }, isFullWake: { true }, uptime: { uptime })
        defer { model.closeSettings() }
        let deadline = Date().addingTimeInterval(2)
        while launches == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        uptime = 20
        while !model.loginServiceUnavailable && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(model.loginServiceUnavailable && launches == 1, "the original startup deadline bounds exited children too")
    }
    test("native login AppleEvent hides Settings but an ordinary launch does not") {
        expect(!LoginLaunch.isLoginEvent(nil), "missing context is an ordinary launch")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        expect(!LoginLaunch.isLoginEvent(event), "ordinary Open Application shows Settings")
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        expect(LoginLaunch.isLoginEvent(event), "the native login marker starts only the background worker")
    }

    test("an available worker is observed without starting either kind of worker") {
        var sessionStarts = 0
        let finish = DispatchSemaphore(value: 0)
        let model = AgentModel(watch: { receive in
            _ = receive(phoneState(.off))
            finish.wait()
            return true
        }, launchAgent: {
            sessionStarts += 1
            return Process()
        }, loginServiceStatus: { .enabled })
        defer { model.closeSettings(); finish.signal() }
        let deadline = Date().addingTimeInterval(2)
        while model.state == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(model.state?.status?.hotspot == .off, "Settings receives current phone status")
        expect(sessionStarts == 0, "no start while a worker serves the socket")
    }

    test("explicit Quit reaches a session worker that is still starting") {
        var starts = 0
        var requests = 0
        let model = AgentModel(watch: { _ in false }, launchAgent: { starts += 1; return Process() }, request: { command in
            guard command == "quit" else { return false }
            requests += 1
            return requests == 2
        }, loginServiceStatus: { .enabled }, isFullWake: { true })
        let deadline = Date().addingTimeInterval(2)
        while starts == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(starts == 1, "registered worker start is pending")
        var finished = false
        model.quit { finished = true }
        let quitDeadline = Date().addingTimeInterval(2)
        while !finished && Date() < quitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(finished && requests == 2, "Quit waits for the starting worker's socket")
        expect(starts == 1, "no further start requested")
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
        }, request: { command in commands.append(command); return false }, isFullWake: { true })
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
