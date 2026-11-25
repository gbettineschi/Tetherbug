import CoreLocation
import CoreWLAN
import Foundation
import OSLog
import SystemConfiguration

enum WifiAccess {
    static func isDisconnected(poweredOn: Bool, linkActive: Bool?) -> Bool { poweredOn && linkActive == false }

    /// Physical association is independent of DHCP, captive portals and internet availability.
    static func linkActive(device: String) -> Bool? {
        let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState,
            device as CFString, kSCEntNetLink)
        guard let value = SCDynamicStoreCopyValue(nil, key) as? [String: Any] else { return nil }
        return value[kSCPropNetLinkActive as String] as? Bool
    }
    static func authorized(_ status: CLAuthorizationStatus) -> Bool { status == .authorizedAlways }

    static func savedNetworks(_ interface: CWInterface) -> Set<String> {
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return Set(profiles.compactMap(\.ssid))
    }

    static func matches(savedSSID: Data, security: CWSecurity, networkSSID: Data?, supports: (CWSecurity) -> Bool) -> Bool {
        savedSSID == networkSSID && security != .unknown && supports(security)
    }
}

/// Only the main queue reads Location authorization. The worker never requests a new grant.
/// A cancellation suppresses delivery; the real blocking scan keeps ownership until it returns.
final class MacWifiPresenceScanner: WifiPresenceScanner {
    typealias Perform = (Set<Data>, @escaping () -> Bool) throws -> Set<Data>
    private final class Operation { var cancelled = false }
    private let activity: PowerActivity
    private let queue: DispatchQueue
    private let authorized: (() -> Bool)?
    private let perform: Perform
    private let lock = NSLock()
    private var operation: Operation?
    private lazy var location = CLLocationManager()

    init(activity: PowerActivity, queue: DispatchQueue, authorized: (() -> Bool)? = nil,
         perform: @escaping Perform = WifiDiscovery.scan) {
        self.activity = activity
        self.queue = queue
        self.authorized = authorized
        self.perform = perform
    }
    var locationAllowed: Bool { authorized?() ?? WifiAccess.authorized(location.authorizationStatus) }
    var pending: Bool { lock.withLock { operation != nil } }
    func cancel() { lock.withLock { operation?.cancelled = true } }

    private func owns(_ operation: Operation) -> Bool {
        lock.withLock { self.operation === operation && !operation.cancelled }
    }

    func scan(_ candidates: Set<Data>, completion: @escaping (Result<Set<Data>, Error>) -> Void) {
        let token = activity.generation
        guard activity.allows(token), locationAllowed else { completion(.failure(WifiDiscovery.Failure.unavailable)); return }
        let op = Operation()
        let acquired = lock.withLock { () -> Bool in
            guard operation == nil else { return false }
            operation = op
            return true
        }
        guard acquired else { completion(.failure(WifiDiscovery.Failure.busy)); return }
        queue.async { [weak self] in
            guard let self else { return }
            let allowed = { self.owns(op) && self.activity.allows(token) }
            let result: Result<Set<Data>, Error>
            if allowed() {
                do { result = .success(try self.perform(candidates, allowed)) }
                catch {
                    let error = error as NSError
                    Logger(subsystem: "ie.xav.tetherbug", category: "wifi").error(
                        "Preferred Wi-Fi scan failed domain=\(error.domain, privacy: .public) code=\(error.code)")
                    result = .failure(WifiDiscovery.Failure.unavailable)
                }
            } else { result = .failure(WifiDiscovery.Failure.cancelled) }
            DispatchQueue.main.async {
                let deliver = self.lock.withLock { () -> Bool in
                    guard self.operation === op else { return false }
                    self.operation = nil
                    return !op.cancelled
                }
                if deliver, self.activity.allows(token), self.locationAllowed { completion(result) }
            }
        }
    }
}

/// Read-only public discovery: never associate, disassociate, access Keychain or change power.
enum WifiDiscovery {
    enum Failure: Error { case unavailable, busy, cancelled }

    static func discoverSaved(_ preferred: Set<Data>, saved: Set<Data>,
                              query: (Set<Data>) throws -> Set<Data>) rethrows -> Set<Data> {
        let candidates = preferred.intersection(saved)
        return candidates.isEmpty ? [] : try query(candidates)
    }

    static func scan(candidates: Set<Data>, allowed: @escaping () -> Bool) throws -> Set<Data> {
        guard allowed() else { throw Failure.cancelled }
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] else { throw Failure.unavailable }
        let known = Set(profiles.filter { $0.security != .unknown }.compactMap(\.ssidData))
        return try discoverSaved(candidates, saved: known) { candidates in
            let profiles = profiles.filter { $0.ssidData.map(candidates.contains) == true }
            guard allowed() else { throw Failure.cancelled }
            let log = Logger(subsystem: "ie.xav.tetherbug", category: "wifi")
            log.info("Preferred Wi-Fi discovery started")
            let networks = try interface.scanForNetworks(withName: nil)
            guard allowed() else { throw Failure.cancelled }
            let visible = Set(networks.compactMap { network -> Data? in
                guard let data = network.ssidData, profiles.contains(where: { profile in
                    guard let saved = profile.ssidData else { return false }
                    return WifiAccess.matches(savedSSID: saved, security: profile.security,
                                              networkSSID: data, supports: network.supportsSecurity)
                }) else { return nil }
                return data
            })
            log.info("Preferred Wi-Fi discovery completed savedVisible=\(visible.count)")
            return visible
        }
    }
}
