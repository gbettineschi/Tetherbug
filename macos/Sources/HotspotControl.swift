import Foundation

enum AutomaticPauseDuration: String, CaseIterable {
    case minutes15, minutes30, hour1, hours2, hours3, today, indefinitely

    var title: String {
        switch self {
        case .minutes15: return "15 minutes"
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours3: return "3 hours"
        case .today: return "Today"
        case .indefinitely: return "Indefinitely"
        }
    }

    func deadline(from now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .minutes15: return now.addingTimeInterval(15 * 60)
        case .minutes30: return now.addingTimeInterval(30 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .hours2: return now.addingTimeInterval(2 * 60 * 60)
        case .hours3: return now.addingTimeInterval(3 * 60 * 60)
        case .today: return calendar.dateInterval(of: .day, for: now)?.end
        case .indefinitely: return nil
        }
    }
}

/// Manual requests and automatic activation share one policy. The phone remains the source of
/// truth for hotspot state; a Bluetooth write is not a confirmation that the hotspot changed.
final class HotspotControl {
    private let defaults: UserDefaults
    private var lastAutomatic: Bool
    private var pending: (on: Bool, sentAt: Date)?
    private var writeStarted: Date?
    private var hotspotWasOn = false
    private(set) var needsReconnect = false
    private(set) var error: String?

    init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
        // Earlier local trials stored indefinite suspension separately. Keep those users off.
        if defaults.bool(forKey: "automaticPausedIndefinitely") {
            defaults.set(false, forKey: "onNoWifi")
            defaults.removeObject(forKey: "automaticPausedUntil")
        }
        defaults.removeObject(forKey: "automaticPausedIndefinitely")
        lastAutomatic = defaults.object(forKey: "onNoWifi") as? Bool ?? true
    }

    var automatic: Bool {
        get { defaults.object(forKey: "onNoWifi") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "onNoWifi")
            lastAutomatic = newValue
            resume()
        }
    }

    private(set) var pausedUntil: Date? {
        get { defaults.object(forKey: "automaticPausedUntil") as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: "automaticPausedUntil") }
            else { defaults.removeObject(forKey: "automaticPausedUntil") }
        }
    }

    /// Menu controls can resume activation even when it was disabled in Settings.
    func setAutomaticActive(_ active: Bool) {
        automatic = active
    }

    func pauseAutomatic(for duration: AutomaticPauseDuration, now: Date = Date(), calendar: Calendar = .current) {
        if duration == .indefinitely {
            setAutomaticActive(false)
            return
        }
        if !automatic { automatic = true }
        pausedUntil = duration.deadline(from: now, calendar: calendar)
    }

    var writePending: Bool { writeStarted != nil }
    var isPending: Bool { pending != nil || writePending }

    func canToggle(_ state: AgentState) -> Bool {
        guard !isPending, state.connected, let status = state.status else { return false }
        return status.controllable && status.hotspot != .starting
    }

    /// Returns the command to send, or nil when the phone cannot currently accept a toggle.
    func toggle(_ state: AgentState, now: Date = Date()) -> Bool? {
        guard canToggle(state) else { return nil }
        let on = state.status?.hotspot != .on
        return beginRequest(on, state: state, now: now, pauseAutomaticWhenTurningOff: true) ? on : nil
    }

    @discardableResult
    func beginRequest(_ on: Bool, state: AgentState, now: Date = Date(),
                      pauseAutomaticWhenTurningOff: Bool = false) -> Bool {
        guard canToggle(state) else { return false }
        if on { resume() }
        else if pauseAutomaticWhenTurningOff && automatic {
            pauseAutomatic(now: now)
        }
        pending = state.status?.hotspot == (on ? .on : .off) ? nil : (on, now)
        writeStarted = pending == nil ? nil : now
        error = nil
        return true
    }

    func shouldAutomaticallyEnable(_ state: AgentState, now: Date = Date()) -> Bool {
        automatic && (pausedUntil.map { $0 <= now } ?? true) && state.wifiOffline &&
            canToggle(state) && state.status?.hotspot != .on
    }

    /// Called by the existing agent timer and by Bluetooth events, never a new polling loop.
    func refresh(_ state: AgentState, now: Date = Date(), receivedStatus: Bool = false) {
        if lastAutomatic != automatic {
            lastAutomatic = automatic
            resume() // a change made from the settings window
        }
        if let pausedUntil, pausedUntil <= now { resume() }
        if !state.connected { hotspotWasOn = false }
        if state.connected, receivedStatus, let status = state.status {
            switch status.hotspot {
            case .on: hotspotWasOn = true
            case .off:
                if hotspotWasOn { pauseAutomatic(now: now) }
                hotspotWasOn = false
            case .starting, .failed: break
            }
        }
        if !state.connected {
            if isPending { commandFailed("Phone disconnected before confirming the change.") }
            writeStarted = nil
            needsReconnect = false
            return
        }
        if let writeStarted, now.timeIntervalSince(writeStarted) >= 15 {
            // Do not let a timeout allow a newer write before this one's callback. The agent
            // resets the connection instead; a callback cannot identify individual GATT writes.
            needsReconnect = true
            commandFailed("Bluetooth did not confirm the command. Reconnecting…")
        }
        guard let pending else { return }
        if state.status?.controllable == false {
            commandFailed("Shizuku is not ready on the phone.")
        } else if receivedStatus && state.status?.hotspot == (pending.on ? .on : .off) {
            self.pending = nil
        } else if receivedStatus && state.status?.hotspot == .failed {
            commandFailed("The phone could not change its hotspot.")
        } else if now.timeIntervalSince(pending.sentAt) >= 15 {
            commandFailed("The phone did not confirm the change. Try again.")
        }
    }

    func resume() {
        pausedUntil = nil
    }

    private func pauseAutomatic(now: Date) {
        guard automatic else { return }
        pausedUntil = max(pausedUntil ?? .distantPast, now.addingTimeInterval(5 * 60))
    }

    /// At most one unresolved transport write exists. A state notification can arrive before
    /// this callback; retain write ownership until both have been accounted for.
    func writeCompleted(error: String?) {
        guard writePending else { return }
        writeStarted = nil
        needsReconnect = false
        if let error { commandFailed(error) }
    }

    func commandFailed(_ message: String) {
        pending = nil
        error = message
    }
}
