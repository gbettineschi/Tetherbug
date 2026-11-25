import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import OSLog

/// One observation, scoped to its interface and awake generation. Never persisted.
struct WifiScanSnapshot<Network> {
    let networks: [Network]
    let interface: String
    let generation: UInt64
    let capturedAt: TimeInterval

    func results(interface: String, generation: UInt64, now: TimeInterval) -> [Network]? {
        guard generation == self.generation else { return nil }
        return freshResults(interface: interface, now: now)
    }

    func freshResults(interface: String, now: TimeInterval) -> [Network]? {
        let age = now - capturedAt
        guard interface == self.interface, age >= 0, age <= 15 else { return nil }
        return networks
    }
}

enum WifiOperationStage: String, Codable {
    case preparation, discoveryScan = "discovery-scan", directedScan = "directed-scan"
    case cacheSeedScan = "cache-seed-scan"
    case personalCredentials = "personal-credentials"
    case openAssociation = "open-association", personalAssociation = "personal-association"
    case enterpriseAssociation = "enterprise-association"
}

/// Copy only safe metadata. In particular, never retain an NSError's userInfo or description.
struct WifiOperationFailure: Error, Codable {
    let stage: WifiOperationStage
    let domain: String
    let code: Int

    init(_ error: Error, stage: WifiOperationStage) {
        if let classified = error as? Self { self = classified; return }
        let error = error as NSError
        self.stage = stage
        domain = error.domain
        code = error.code
    }

    static func perform<T>(_ stage: WifiOperationStage, _ body: () throws -> T) throws -> T {
        let log = Logger(subsystem: "ie.xav.tetherbug", category: "wifi")
        log.info("CoreWLAN started stage=\(stage.rawValue, privacy: .public)")
        do {
            let value = try body()
            log.info("CoreWLAN completed stage=\(stage.rawValue, privacy: .public)")
            return value
        } catch { throw Self(error, stage: stage) }
    }

    func log() {
        Logger(subsystem: "ie.xav.tetherbug", category: "wifi").error(
            "CoreWLAN failed stage=\(stage.rawValue, privacy: .public) domain=\(domain, privacy: .public) code=\(code)")
    }
}

/// Bounded read-only reproduction of the old discovery + directed-scan sequence.
/// This reports scan results, never association or authentication success.
enum WifiScanDiagnostic {
    struct Step: Encodable {
        let stage: WifiOperationStage
        let elapsedSeconds: Double
        let count: Int
        let targetSeen: Bool
        let failure: WifiOperationFailure?
    }
    struct Report: Encodable {
        let kind = "scan-only"
        var refusal: String?
        var steps: [Step] = []
        var sameSSIDBeforeAndAfter: Bool?
        var locationAuthorization: Int32?
        var succeeded: Bool {
            refusal == nil && steps.count == 2 && steps.allSatisfy { $0.failure == nil && $0.targetSeen }
        }
    }

    static func run(target: Data, allowed: () -> Bool, scan: (Data?) throws -> [Data]) -> Report {
        var report = Report()
        guard !target.isEmpty, target.count <= 32 else { report.refusal = "invalid-target"; return report }
        for stage: WifiOperationStage in [.discoveryScan, .directedScan] {
            guard allowed() else { report.refusal = "not-permitted"; return report }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let networks = try WifiOperationFailure.perform(stage) { try scan(stage == .discoveryScan ? nil : target) }
                let seen = networks.contains(target)
                report.steps.append(Step(stage: stage, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                         count: networks.count, targetSeen: seen, failure: nil))
                if !seen { return report }
            } catch {
                report.steps.append(Step(stage: stage, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                         count: 0, targetSeen: false, failure: WifiOperationFailure(error, stage: stage)))
                return report
            }
        }
        return report
    }

    @MainActor
    static func runOnMac(target: String) -> Report {
        // Use the worker's existing lifetime lease, not another radio operation owner.
        // This command only runs while the worker is stopped, and prevents a concurrent start.
        guard let lease = AgentLock(path: Socket.path + ".lock") else {
            return Report(refusal: "agent-lock-unavailable")
        }
        return withExtendedLifetime(lease) { runExclusivelyOnMac(target: target) }
    }

    @MainActor
    private static func runExclusivelyOnMac(target: String) -> Report {
        guard PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) else {
            return Report(refusal: "not-permitted")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard !Settings.returnToPreferredWifi, !WifiPreferenceControl().prefersHotspot() else {
            return Report(refusal: "automatic-switching-enabled")
        }
        // The normal app has a running event loop. This short-lived command must allow
        // Core Location's initial authorization callback before interpreting its state.
        let observer = AuthorizationObserver()
        let location = CLLocationManager()
        location.delegate = observer
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while observer.status == nil, ProcessInfo.processInfo.systemUptime < deadline,
              PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) else { return Report(refusal: "not-permitted") }
        guard let authorization = observer.status else { return Report(refusal: "location-status-unavailable") }
        guard WifiAccess.authorized(authorization) else {
            return Report(refusal: "location-not-authorized", locationAuthorization: authorization.rawValue)
        }
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            return Report(refusal: "interface-unavailable")
        }
        let targetData = Data(target.utf8)
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        guard profiles.contains(where: { $0.ssidData == targetData }) else { return Report(refusal: "target-not-saved") }
        let previous = interface.ssidData()
        var report = run(target: targetData, allowed: {
            PowerActivity.isFullWake(SystemPowerMonitor.capabilities()) &&
            !Settings.returnToPreferredWifi && !WifiPreferenceControl().prefersHotspot()
        }, scan: { ssid in
            let networks = try ssid.map { try interface.scanForNetworks(withSSID: $0) }
                ?? interface.scanForNetworks(withName: nil)
            return networks.compactMap(\.ssidData)
        })
        if PowerActivity.isFullWake(SystemPowerMonitor.capabilities()),
           let previous, let current = interface.ssidData() {
            report.sameSSIDBeforeAndAfter = previous == current
        }
        return report
    }

    private final class AuthorizationObserver: NSObject, CLLocationManagerDelegate {
        var status: CLAuthorizationStatus?
        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            status = manager.authorizationStatus
        }
    }
}
