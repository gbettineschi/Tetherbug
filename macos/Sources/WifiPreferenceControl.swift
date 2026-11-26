import Foundation

/// Native network-change courtesy; Automatic Mode is the sole automation switch.
final class WifiPreferenceControl {
    private let defaults: UserDefaults
    private var lastNetwork: String?
    private var observed = false
    private var observedDisconnected = false
    static let offCooldown: TimeInterval = 5 * 60

    init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
        defaults.removeObject(forKey: "preferHotspotUntil")
        if defaults.object(forKey: "preferredWifiOffNotBefore") == nil,
           let old = defaults.object(forKey: "wifiSwitchNotBefore") as? Date {
            defaults.set(old, forKey: "preferredWifiOffNotBefore")
        }
        defaults.removeObject(forKey: "wifiSwitchNotBefore")
    }

    var offNotBefore: Date? { defaults.object(forKey: "preferredWifiOffNotBefore") as? Date }

    func canTurnOff(now: Date = Date()) -> Bool { offNotBefore.map { $0 <= now } ?? true }

    func refresh(now: Date = Date()) {
        if let expiry = offNotBefore, expiry <= now { defaults.removeObject(forKey: "preferredWifiOffNotBefore") }
    }

    /// Give a native/manual network change five minutes before automatic hotspot Off.
    /// Repeated reports or a temporary nil name do not extend that courtesy period.
    func observeNetwork(_ ssid: String?, disconnected: Bool = false, now: Date = Date()) {
        guard let ssid else {
            if disconnected && !observedDisconnected && observed && lastNetwork != nil {
                defaults.set(now.addingTimeInterval(Self.offCooldown), forKey: "preferredWifiOffNotBefore")
            }
            if disconnected { observedDisconnected = true }
            return
        }
        defer { lastNetwork = ssid; observed = true; observedDisconnected = false }
        guard observed, lastNetwork != ssid else { return }
        defaults.set(now.addingTimeInterval(Self.offCooldown), forKey: "preferredWifiOffNotBefore")
    }
}
