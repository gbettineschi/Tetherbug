import Foundation

enum WifiNetworkNames {
    static func error(for name: String, existing: [String], hotspot: String?) -> String? {
        if name.isEmpty || name.utf8.count > 32 { return "Enter a Wi-Fi name of 1–32 bytes." }
        if name == hotspot { return "Choose a network other than your phone’s hotspot." }
        if existing.contains(name) { return "This network is already in the list." }
        return nil
    }
}

/// Effects run asynchronously; cancellation must invalidate their outstanding callbacks too.
protocol WifiHandoverService: AnyObject {
    func scan(_ completion: @escaping (Set<String>) -> Void)
    func join(_ ssid: String, completion: @escaping (Bool) -> Void)
    func verifyInternet(_ completion: @escaping (Bool) -> Void)
    func cancel()
}

/// Main-queue policy. Seeing a preferred network is never sufficient to turn the phone off.
final class WifiHandover {
    struct Context {
        var allowed: Bool
        var enabled: Bool
        var automaticActive: Bool
        var preferred: [String]
        var currentSSID: String?
        var wifiConnected: Bool
        var hotspotSSID: String?
        var hotspotOn: Bool
        var canControlHotspot: Bool
        var wifiPoweredOn: Bool
        var locationAllowed: Bool

        var candidates: [String] {
            preferred.filter { WifiNetworkNames.error(for: $0, existing: [], hotspot: hotspotSSID) == nil }
        }
        var canRun: Bool {
            allowed && enabled && automaticActive && hotspotOn && canControlHotspot &&
                wifiPoweredOn && locationAllowed && hotspotSSID?.isEmpty == false && !candidates.isEmpty
        }
        var usingHotspotOrOffline: Bool {
            currentSSID == hotspotSSID || (!wifiConnected && currentSSID == nil)
        }
    }

    private enum Phase {
        case idle, scanning, joining(String), settling(String, Date), verifying(String), restoring
    }
    private let service: WifiHandoverService
    private let context: () -> Context
    private let now: () -> Date
    private let turnOff: () -> Void
    private let report: (String?) -> Void
    private var phase = Phase.idle
    private var epoch: UInt64 = 0
    private var preferred: [String] = []
    private var hotspot: String?
    private var stableSince: Date?
    private var attemptedSSID: String?
    private var nextScan = Date.distantPast
    private var failedUntil: [String: Date] = [:]

    var busy: Bool {
        switch phase {
        case .joining, .settling, .verifying, .restoring: return true
        case .idle, .scanning: return false
        }
    }

    init(service: WifiHandoverService, context: @escaping () -> Context,
         now: @escaping () -> Date = Date.init, turnOff: @escaping () -> Void,
         report: @escaping (String?) -> Void = { _ in }) {
        self.service = service
        self.context = context
        self.now = now
        self.turnOff = turnOff
        self.report = report
    }

    func cancel() {
        epoch &+= 1
        service.cancel()
        phase = .idle
        stableSince = nil
        attemptedSSID = nil
        preferred = []
        hotspot = nil
        report(nil)
    }

    /// Called by the existing maintenance timer and Wi-Fi/Bluetooth notifications.
    func tick() {
        let c = context()
        guard c.canRun else {
            if case .idle = phase {} else { cancel() }
            return
        }
        if preferred != c.preferred || hotspot != c.hotspotSSID {
            cancel()
            preferred = c.preferred
            hotspot = c.hotspotSSID
        }
        let date = now()
        switch phase {
        case let .settling(target, deadline):
            if let current = c.currentSSID, current != target, current != hotspot { cancel(); return }
            if date >= deadline { fail(target); return }
            guard c.currentSSID == target, c.wifiConnected else { stableSince = nil; return }
            if stableSince == nil { stableSince = date }
            guard date.timeIntervalSince(stableSince!) >= 3 else { return }
            verify(target)
        case let .verifying(target):
            if c.currentSSID != target || !c.wifiConnected { connectionLost(target) }
        case .idle:
            if let current = c.currentSSID, c.candidates.contains(current), c.wifiConnected {
                guard (failedUntil[current] ?? .distantPast) <= date else { return }
                attemptedSSID = nil // observed native/manual join: nothing for us to undo
                settle(current)
            } else if c.usingHotspotOrOffline, date >= nextScan {
                scan()
            }
        case let .joining(target):
            if let current = c.currentSSID, current != target, current != hotspot { cancel() }
        case .restoring:
            if let current = c.currentSSID, current != attemptedSSID, current != hotspot { cancel() }
        case .scanning: break
        }
    }

    /// A fresh context check protects the gap between a system change and the next timer tick.
    private func accepts(_ id: UInt64) -> Bool {
        guard id == epoch else { return false }
        let c = context()
        guard c.canRun, c.preferred == preferred, c.hotspotSSID == hotspot else { cancel(); return false }
        return true
    }

    private func scan() {
        phase = .scanning
        nextScan = now().addingTimeInterval(60)
        let id = epoch
        service.scan { [weak self] visible in
            guard let self, self.accepts(id) else { return }
            let c = self.context()
            guard c.usingHotspotOrOffline else { self.cancel(); return }
            guard let target = c.candidates.first(where: {
                visible.contains($0) && (self.failedUntil[$0] ?? .distantPast) <= self.now()
            }) else { self.phase = .idle; return }
            self.attemptedSSID = target
            self.phase = .joining(target)
            self.report("Connecting to \(target)…")
            self.service.join(target) { [weak self] success in
                guard let self, self.accepts(id) else { return }
                if success { self.settle(target) }
                else { self.fail(target) }
            }
        }
    }

    private func settle(_ target: String) {
        phase = .settling(target, now().addingTimeInterval(20))
        stableSince = context().currentSSID == target && context().wifiConnected ? now() : nil
        report("Checking \(target)…")
    }

    private func verify(_ target: String) {
        phase = .verifying(target)
        let id = epoch
        service.verifyInternet { [weak self] success in
            guard let self, self.accepts(id) else { return }
            let c = self.context()
            guard c.currentSSID == target, c.wifiConnected else { self.connectionLost(target); return }
            if success {
                self.cancel()
                self.turnOff()
            } else { self.fail(target) }
        }
    }

    private func fail(_ target: String) {
        failedUntil[target] = now().addingTimeInterval(5 * 60)
        let c = context()
        phase = .idle
        stableSince = nil
        report("Couldn’t use \(target). Keeping the hotspot on.")
        // Do not undo a manual network change; restore only the failed attempt's connection.
        guard attemptedSSID == target, let hotspot,
              c.currentSSID == target || (!c.wifiConnected && c.currentSSID == nil) else { return }
        phase = .restoring
        let id = epoch
        service.join(hotspot) { [weak self] _ in
            guard let self, self.accepts(id) else { return }
            self.phase = .idle
        }
    }

    private func connectionLost(_ target: String) {
        let c = context()
        if c.currentSSID == nil || c.currentSSID == target || c.currentSSID == hotspot { fail(target) }
        else { cancel() } // a different user-selected network owns the connection now
    }
}
