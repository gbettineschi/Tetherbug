import CoreWLAN
import Foundation
import Security
import OSLog

/// A timeout/cancellation does not stop a blocking public CoreWLAN association.
struct WifiAssociationState {
    var submitted = false
    private(set) var pending = true
    private(set) var canDeliver = true
    mutating func abandon(forSleep: Bool = false) { canDeliver = false }

    /// Called only when the blocking operation actually returned, never for a cancel ACK.
    mutating func complete() -> Bool {
        guard pending else { return false }
        pending = false
        let deliver = canDeliver
        canDeliver = false
        return deliver
    }
}

/// Owns one blocking public association until it returns. Cancellation suppresses its result.
final class NativeWifiAssociation {
    typealias Perform = (String, String, @escaping () -> Bool) throws -> Void
    private final class Operation { var state = WifiAssociationState() }
    private let queue: DispatchQueue
    private let perform: Perform
    private let lock = NSLock()
    private var current: Operation?

    init(queue: DispatchQueue, perform: @escaping Perform = CoreWLANAssociation.join) {
        self.queue = queue
        self.perform = perform
    }
    var pending: Bool { lock.withLock { current != nil } }
    func cancel() { lock.withLock { current?.state.abandon() } }
    func suspend() { lock.withLock { current?.state.abandon(forSleep: true) } }
    // A wake cannot release an association still running in CoreWLAN.
    func resumeAfterSleep() {}

    private func owns(_ operation: Operation) -> Bool {
        lock.withLock { current === operation && operation.state.canDeliver }
    }

    func join(_ ssid: String, device: String, allowed: @escaping () -> Bool,
              completion: @escaping (Bool) -> Void) {
        guard allowed() else { completion(false); return }
        let operation = Operation()
        let acquired = lock.withLock { () -> Bool in
            guard current == nil else { return false }
            current = operation
            return true
        }
        guard acquired else { completion(false); return }
        queue.async { [weak self] in
            guard let self else { return }
            var success = false
            if self.owns(operation), allowed() {
                self.lock.withLock { operation.state.submitted = true }
                do {
                    try self.perform(ssid, device, { self.owns(operation) && allowed() })
                    success = true
                } catch {
                    let error = error as NSError
                    // Never log localizedDescription/userInfo: they can contain credentials.
                    Logger(subsystem: "ie.xav.tetherbug", category: "wifi").error(
                        "CoreWLAN association failed (\(error.domain, privacy: .public), code \(error.code))")
                }
            }
            let result = success
            DispatchQueue.main.async {
                let deliver = self.lock.withLock { () -> Bool in
                    guard self.current === operation else { return false }
                    let deliver = operation.state.complete()
                    self.current = nil
                    return deliver
                }
                if deliver, allowed() { completion(result) }
            }
        }
    }
}

/// Documented CoreWLAN radio and Keychain operations. No profile or trust setting is edited.
enum CoreWLANAssociation {
    enum Failure: Error { case unavailable, notSaved, notVisible, cancelled, credentialsUnavailable }
    enum Authentication { case open, personal, enterprise }
    private static let keychainLock = NSRecursiveLock()

    static func matches(savedSSID: Data, security: CWSecurity, networkSSID: Data?, supports: (CWSecurity) -> Bool) -> Bool {
        savedSSID == networkSSID && security != .unknown && supports(security)
    }

    static func credentialFound(_ status: OSStatus) throws -> Bool {
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound || status == errSecNoSuchKeychain { return false }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    /// CoreWLAN's helpers use the legacy macOS Wi-Fi Keychain. Its documented interaction
    /// switch is process-local; serialize it and always restore it, including when lookup fails.
    static func withoutKeychainInteraction<T>(_ body: () throws -> T) throws -> T {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        var original: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw Failure.credentialsUnavailable
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(original.boolValue) }
        return try body()
    }

    static func authentication(supports: (CWSecurity) -> Bool) -> Authentication {
        if [.enterprise, .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise].contains(where: supports) {
            return .enterprise
        }
        if [.none, .OWE, .oweTransition].contains(where: supports) { return .open }
        return .personal
    }

    static func join(_ ssid: String, device: String, allowed: @escaping () -> Bool) throws {
        guard allowed() else { throw Failure.cancelled }
        guard let interface = CWWiFiClient.shared().interface(withName: device), interface.powerOn() else {
            throw Failure.unavailable
        }
        let data = Data(ssid.utf8)
        let profiles = (interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? [])
            .filter { $0.ssidData == data && $0.security != .unknown }
        guard !profiles.isEmpty else { throw Failure.notSaved }
        guard interface.configuration()?.requireAdministratorForAssociation != true else { throw Failure.unavailable }
        guard allowed() else { throw Failure.cancelled }
        let networks = try interface.scanForNetworks(withSSID: data)
        let matches = networks.compactMap { network -> (CWNetwork, CWNetworkProfile)? in
            guard let profile = profiles.first(where: {
                Self.matches(savedSSID: data, security: $0.security, networkSSID: network.ssidData,
                        supports: network.supportsSecurity)
            }) else { return nil }
            return (network, profile)
        }
        guard let (network, profile) = matches.max(by: { $0.0.rssiValue < $1.0.rssiValue }) else {
            throw Failure.notVisible
        }
        guard allowed() else { throw Failure.cancelled }
        switch authentication(supports: { $0 == profile.security }) {
        case .open:
            try interface.associate(to: network, password: nil)
        case .personal:
            let password: NSString? = try withoutKeychainInteraction {
                var value: NSString?
                for domain: CWKeychainDomain in [.user, .system] {
                    if try credentialFound(CWKeychainFindWiFiPassword(domain, data, &value)) { break }
                }
                return value
            }
            guard let password else { throw Failure.credentialsUnavailable }
            guard allowed() else { throw Failure.cancelled }
            try interface.associate(to: network, password: password as String)
        case .enterprise:
            var (username, password, identity): (NSString?, NSString?, SecIdentity?) = try withoutKeychainInteraction {
                var username: NSString?
                var password: NSString?
                var identity: SecIdentity?
                for domain: CWKeychainDomain in [.user, .system] {
                    if try credentialFound(CWKeychainFindWiFiEAPUsernameAndPassword(domain, data, &username, &password)) { break }
                }
                for domain: CWKeychainDomain in [.user, .system] {
                    var value: Unmanaged<SecIdentity>?
                    if try credentialFound(CWKeychainCopyWiFiEAPIdentity(domain, data, &value)) {
                        identity = value?.takeRetainedValue()
                        break
                    }
                }
                return (username, password, identity)
            }
            if identity == nil, (username?.length ?? 0) == 0 || (password?.length ?? 0) == 0 {
                let saved = try withoutKeychainInteraction { try WifiCredentialStore.read(ssid: ssid) }
                username = saved.username as NSString?
                password = saved.password as NSString
            }
            guard identity != nil || ((username?.length ?? 0) > 0 && (password?.length ?? 0) > 0) else {
                throw Failure.credentialsUnavailable
            }
            guard allowed() else { throw Failure.cancelled }
            // Missing/denied credentials fail closed. Never invent an EAP profile or disable
            // server-certificate validation to force an unattended join.
            try interface.associate(toEnterpriseNetwork: network, identity: identity,
                                    username: username as String?, password: password as String?)
        }
    }
}
