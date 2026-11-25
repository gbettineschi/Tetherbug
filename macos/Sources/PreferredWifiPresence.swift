import Foundation

enum WifiNetworkNames {
    static func error(for name: String, existing: [String], hotspot: String?) -> String? {
        if name.isEmpty || name.utf8.count > 32 { return "Enter a Wi-Fi name of 1–32 bytes." }
        if name == hotspot { return "Choose a network other than your phone’s hotspot." }
        if existing.contains(name) { return "This network is already in the list." }
        return nil
    }
}


/// Discovery only. Implementations retain `pending` until the real OS call returns.
protocol WifiPresenceScanner: AnyObject {
    var pending: Bool { get }
    func scan(_ candidates: Set<Data>, completion: @escaping (Result<Set<Data>, Error>) -> Void)
    func cancel()
}

/// Main-queue policy. macOS alone owns network association and saved authentication.
final class PreferredWifiPresence {
    struct Context {
        var allowed: Bool
        var automaticActive: Bool
        var phoneReady: Bool
        var canTurnOff: Bool
        var hotspotOn: Bool
        var wifiDisconnected: Bool
        var wifiPoweredOn: Bool
        var locationAllowed: Bool
        var preferred: [String]
        var hotspotSSID: String?
        var preferHotspot = false
        var courtesyElapsed = true

        var identities: Set<Data> {
            Set(preferred.filter { WifiNetworkNames.error(for: $0, existing: [], hotspot: hotspotSSID) == nil }
                .map { Data($0.utf8) })
        }
        var eligible: Bool {
            guard let hotspotSSID, !hotspotSSID.isEmpty, hotspotSSID.utf8.count <= 32 else { return false }
            return allowed && automaticActive && phoneReady && wifiPoweredOn && locationAllowed &&
                !preferHotspot && !identities.isEmpty
        }
    }

    private enum Observation { case visible, absent, unavailable }
    private let scanner: WifiPresenceScanner
    private let context: () -> Context
    private let now: () -> Date
    private let turnOff: () -> Void
    private let report: (String?) -> Void
    private var configuration: Set<Data>?
    private var epoch: UInt64 = 0
    private var deadline: Date?
    private var submitted = false
    private var observation: (value: Observation, date: Date)?
    private var nextScan = Date.distantPast

    init(scanner: WifiPresenceScanner, context: @escaping () -> Context,
         now: @escaping () -> Date = Date.init, turnOff: @escaping () -> Void,
         report: @escaping (String?) -> Void = { _ in }) {
        self.scanner = scanner
        self.context = context
        self.now = now
        self.turnOff = turnOff
        self.report = report
    }

    var blocksAutomaticEnable: Bool {
        let c = context()
        guard c.eligible, c.wifiDisconnected else { return false }
        guard let value = freshObservation(at: now()) else { return true }
        return value == .visible
    }

    private func freshObservation(at date: Date) -> Observation? {
        guard let observation, date.timeIntervalSince(observation.date) >= 0,
              date.timeIntervalSince(observation.date) < 90 else { return nil }
        return observation.value
    }

    func cancel() {
        epoch &+= 1
        scanner.cancel()
        configuration = nil
        deadline = nil
        submitted = false
        observation = nil
        report(nil)
    }

    func tick() {
        let c = context()
        guard c.eligible else {
            if configuration != nil { cancel() }
            return
        }
        if configuration != c.identities {
            cancel()
            configuration = c.identities
        }
        guard c.hotspotOn || c.wifiDisconnected else {
            if deadline != nil { cancel() }
            return
        }
        let date = now()
        if let deadline, date >= deadline {
            epoch &+= 1
            scanner.cancel() // suppress delivery, but never release actual OS ownership
            self.deadline = nil
            submitted = false
            observation = (.unavailable, date)
            report("Preferred Wi-Fi couldn’t be checked.")
            return
        }
        if deadline == nil {
            guard date >= nextScan || (c.wifiDisconnected && freshObservation(at: date) == nil) else { return }
            deadline = date.addingTimeInterval(15)
        }
        // The budget includes waiting for a scan left running across cancel/sleep.
        guard !submitted, !scanner.pending, date >= nextScan else { return }
        submitted = true
        epoch &+= 1
        nextScan = date.addingTimeInterval(60)
        let id = epoch
        scanner.scan(c.identities) { [weak self] result in
            guard let self, id == self.epoch, self.deadline != nil, self.submitted else { return }
            let fresh = self.context()
            guard fresh.eligible, fresh.identities == self.configuration else { self.cancel(); return }
            guard let deadline = self.deadline, self.now() < deadline else { self.tick(); return }
            self.deadline = nil
            self.submitted = false
            switch result {
            case let .success(visible):
                let found = !visible.isDisjoint(with: fresh.identities)
                self.observation = (found ? .visible : .absent, self.now())
                self.report(found ? "Preferred Wi-Fi is nearby." : nil)
                if found, fresh.hotspotOn, fresh.canTurnOff, fresh.courtesyElapsed { self.turnOff() }
            case .failure:
                // An unavailable scan is not proof of absence. It must neither send Off
                // nor leave a disconnected Mac waiting indefinitely for internet access.
                self.observation = (.unavailable, self.now())
                self.report("Preferred Wi-Fi couldn’t be checked.")
            }
        }
    }
}
