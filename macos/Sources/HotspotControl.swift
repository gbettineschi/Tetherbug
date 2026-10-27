import Foundation

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
            pausedUntil = now.addingTimeInterval(15 * 60)
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

    func resume() { pausedUntil = nil }

    private func pauseAutomatic(now: Date) {
        guard automatic else { return }
        pausedUntil = max(pausedUntil ?? .distantPast, now.addingTimeInterval(15 * 60))
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
