import CoreWLAN
import Foundation
import Security

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
                    log("CoreWLAN association failed (\(error.domain), code \(error.code))")
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

    static func authentication(supports: (CWSecurity) -> Bool) -> Authentication {
        if [.enterprise, .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise].contains(where: supports) {
            return .enterprise
        }
        if [.none, .owe, .oweTransition].contains(where: supports) { return .open }
        return .personal
    }

    static func join(_ ssid: String, device: String, allowed: @escaping () -> Bool) throws {
        guard allowed() else { throw Failure.cancelled }
        guard let interface = CWWiFiClient.shared().interface(withName: device), interface.powerOn() else {
            throw Failure.unavailable
        }
        guard WifiAccess.savedNetworks(interface).contains(ssid) else { throw Failure.notSaved }
        let data = Data(ssid.utf8)
        guard allowed() else { throw Failure.cancelled }
        let networks = try interface.scanForNetworks(withSSID: data)
        guard let network = networks.filter({ $0.ssidData == data }).max(by: { $0.rssiValue < $1.rssiValue }) else {
            throw Failure.notVisible
        }
        guard allowed() else { throw Failure.cancelled }
        switch authentication(supports: network.supportsSecurity) {
        case .open:
            try interface.associate(to: network, password: nil)
        case .personal:
            var password: NSString?
            for domain: CWKeychainDomain in [.user, .system] {
                if CWKeychainFindWiFiPassword(domain, data, &password) == errSecSuccess { break }
            }
            guard let password else { throw Failure.credentialsUnavailable }
            guard allowed() else { throw Failure.cancelled }
            try interface.associate(to: network, password: password as String)
        case .enterprise:
            var username: NSString?
            var password: NSString?
            var identity: SecIdentity?
            for domain: CWKeychainDomain in [.user, .system] {
                if CWKeychainFindWiFiEAPUsernameAndPassword(domain, data, &username, &password) == errSecSuccess { break }
            }
            for domain: CWKeychainDomain in [.user, .system] {
                var value: Unmanaged<SecIdentity>?
                if CWKeychainCopyWiFiEAPIdentity(domain, data, &value) == errSecSuccess {
                    identity = value?.takeRetainedValue()
                    break
                }
            }
            guard allowed() else { throw Failure.cancelled }
            // Nil fields permit native saved/system authentication. Never invent an EAP profile
            // or disable server-certificate validation to force an unattended join.
            try interface.associate(toEnterpriseNetwork: network, identity: identity,
                                    username: username as String?, password: password as String?)
        }
    }
}
