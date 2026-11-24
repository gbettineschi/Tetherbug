import Foundation

/// Separate persisted intent: hotspot preference never changes the Automatic Mode suspension.
final class WifiPreferenceControl {
    private let defaults: UserDefaults
    private var lastNetwork: String?
    private var observed = false
    private var observedDisconnected = false
    static let switchCooldown: TimeInterval = 5 * 60

    init(defaults: UserDefaults = Settings.defaults) { self.defaults = defaults }

    var hotspotUntil: Date? { defaults.object(forKey: "preferHotspotUntil") as? Date }
    var switchNotBefore: Date? { defaults.object(forKey: "wifiSwitchNotBefore") as? Date }

    func prefersHotspot(now: Date = Date()) -> Bool { hotspotUntil.map { $0 > now } ?? false }
    func canSwitch(now: Date = Date()) -> Bool { switchNotBefore.map { $0 <= now } ?? true }

    func preferHotspot(for duration: AutomaticPauseDuration, now: Date = Date(), calendar: Calendar = .current) {
        guard let deadline = duration.deadline(from: now, calendar: calendar) else { return }
        defaults.set(deadline, forKey: "preferHotspotUntil")
    }

    func stopPreferringHotspot() { defaults.removeObject(forKey: "preferHotspotUntil") }

    func refresh(now: Date = Date()) {
        if let expiry = hotspotUntil, expiry <= now { stopPreferringHotspot() }
        if let expiry = switchNotBefore, expiry <= now { defaults.removeObject(forKey: "wifiSwitchNotBefore") }
    }

    /// macOS does not expose whether a non-owned association came from its UI or auto-join.
    /// Both get the same courtesy delay. A nil gap does not lose the previous network baseline.
    func observeNetwork(_ ssid: String?, ownedTarget: String?, disconnected: Bool = false, now: Date = Date()) {
        guard let ssid else {
            if disconnected && !observedDisconnected && observed && lastNetwork != nil && ownedTarget == nil {
                defaults.set(now.addingTimeInterval(Self.switchCooldown), forKey: "wifiSwitchNotBefore")
            }
            if disconnected { observedDisconnected = true }
            return
        }
        defer { lastNetwork = ssid; observed = true; observedDisconnected = false }
        guard observed, lastNetwork != ssid, ssid != ownedTarget else { return }
        defaults.set(now.addingTimeInterval(Self.switchCooldown), forKey: "wifiSwitchNotBefore")
    }
}

/// Quality fallback exists only inside explicit hotspot preference. No extra persistent timer.
final class HotspotInternetFallback {
    struct Context {
        var allowed: Bool
        var currentSSID: String?
    }
    private let context: () -> Context
    private let probe: (@escaping (WifiInternetResult) -> Void) -> Void
    private let cancelProbe: () -> Void
    private let enable: () -> Void
    private let now: () -> Date
    private var epoch: UInt64 = 0
    private var busy = false
    private var network: String?
    private var failures = 0
    private var nextProbe = Date.distantPast

    init(context: @escaping () -> Context, probe: @escaping (@escaping (WifiInternetResult) -> Void) -> Void,
         cancel: @escaping () -> Void, enable: @escaping () -> Void, now: @escaping () -> Date = Date.init) {
        self.context = context; self.probe = probe; cancelProbe = cancel; self.enable = enable; self.now = now
    }

    func cancel() {
        epoch &+= 1
        if busy { cancelProbe() }
        busy = false
        failures = 0
        network = nil
        nextProbe = .distantPast
    }

    func tick() {
        let c = context()
        guard c.allowed, let ssid = c.currentSSID else {
            if busy || network != nil { cancel() }
            return
        }
        if network != ssid {
            cancel()
            network = ssid
            nextProbe = now().addingTimeInterval(30) // allow authentication/DHCP to settle
        }
        guard !busy, now() >= nextProbe else { return }
        busy = true
        let id = epoch
        probe { [weak self] result in
            guard let self, id == self.epoch else { return }
            self.busy = false
            let current = self.context()
            guard current.allowed, current.currentSSID == ssid else { self.cancel(); return }
            if result != .offline {
                self.failures = 0
                self.nextProbe = self.now().addingTimeInterval(60)
            } else {
                self.failures += 1
                self.nextProbe = self.now().addingTimeInterval(15)
                if self.failures >= 2 {
                    self.failures = 0
                    self.nextProbe = self.now().addingTimeInterval(5 * 60)
                    self.enable()
                }
            }
        }
    }
}
