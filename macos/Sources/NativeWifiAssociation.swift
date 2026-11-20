import Foundation

/// Reporting failure does not establish that airportd has finished an in-flight association.
struct WifiAssociationState {
    var submitted = false
    private(set) var pending = true
    private(set) var canDeliver = true
    private var suspended = false

    mutating func abandon(forSleep: Bool = false) {
        canDeliver = false
        suspended = suspended || forSleep
    }

    mutating func complete() -> Bool {
        guard pending, !suspended || !submitted else { return false }
        pending = false
        let deliver = canDeliver
        canDeliver = false
        return deliver
    }
}

/// Join the exact saved profile, allowing macOS to start its enterprise supplicant and retrieve
/// credentials itself. The legacy networksetup command can associate without starting 802.1X.
/// CoreWiFi is also used by the existing channel scanner; missing APIs fail without joining.
final class NativeWifiAssociation {
    private struct Types {
        let interface: NSObject.Type
        let scan: NSObject.Type
        let association: NSObject.Type

        static func load() -> Types? {
            guard dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_LAZY) != nil,
                  let interface = NSClassFromString("CWFInterface") as? NSObject.Type,
                  let scan = NSClassFromString("CWFScanParameters") as? NSObject.Type,
                  let association = NSClassFromString("CWFAssocParameters") as? NSObject.Type else { return nil }
            let methods: [(NSObject.Type, [String])] = [
                (interface, ["activate", "invalidate", "requestParameters", "performScanWithParameters:error:",
                    "knownNetworkProfileMatchingScanResult:", "associateWithParameters:reply:", "cancelRequestsWithUUID:error:"]),
                (scan, ["setSSID:", "setIncludeMatchingKnownNetworkProfiles:"]),
                (association, ["setScanResult:", "setKnownNetworkProfile:", "setRememberUponSuccessfulAssociation:", "setForceBSSID:"])
            ]
            guard methods.allSatisfy({ type, selectors in
                selectors.allSatisfy { type.instancesRespond(to: NSSelectorFromString($0)) }
            }) else { return nil }
            return Types(interface: interface, scan: scan, association: association)
        }
    }

    private final class Operation {
        let interface: NSObject
        let id = NSUUID()
        var parameters: NSObject?
        var reply: AnyObject?
        var state = WifiAssociationState()
        init(_ interface: NSObject) { self.interface = interface }
    }

    private typealias Scan = @convention(c) (AnyObject, Selector, AnyObject,
        AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias Reply = @convention(block) (NSError?) -> Void
    private typealias Associate = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
    private typealias Cancel = @convention(c) (AnyObject, Selector, AnyObject,
        AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var current: Operation?

    init(queue: DispatchQueue) { self.queue = queue }

    private func owns(_ operation: Operation) -> Bool {
        lock.withLock { current === operation && operation.state.canDeliver }
    }

    var pending: Bool { lock.withLock { current != nil } }

    func cancel() {
        lock.withLock { current?.state.abandon() }
        // Do not cancel a submitted OS association here. Its original reply releases ownership;
        // rejecting later joins until then prevents a timeout from creating competing requests.
    }

    func suspend() {
        let operation = lock.withLock { () -> Operation? in
            current?.state.abandon(forSleep: true)
            return current
        }
        guard let operation else { return }
        queue.async {
            let selector = NSSelectorFromString("cancelRequestsWithUUID:error:")
            let cancel = unsafeBitCast(operation.interface.method(for: selector), to: Cancel.self)
            var error: NSError?
            _ = cancel(operation.interface, selector, operation.id, &error)
        }
    }

    func resumeAfterSleep() {
        let operation = lock.withLock { () -> Operation? in
            let old = current
            current = nil
            return old
        }
        if let operation { queue.async { self.invalidate(operation) } }
    }

    func join(_ ssid: String, device: String, allowed: @escaping () -> Bool,
              completion: @escaping (Bool) -> Void) {
        guard !pending, allowed(), let types = Types.load() else { completion(false); return }
        let operation = Operation(types.interface.init())
        lock.withLock { current = operation }
        queue.async { [weak self, operation] in
            guard let self else { return }
            guard self.owns(operation), allowed() else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            let interface = operation.interface
            guard let request = interface.value(forKey: "requestParameters") as? NSObject,
                  request.responds(to: NSSelectorFromString("setUUID:")),
                  request.responds(to: NSSelectorFromString("setInterfaceName:")) else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            request.setValue(operation.id, forKey: "UUID")
            request.setValue(device, forKey: "interfaceName")
            if interface.responds(to: NSSelectorFromString("setRequestParameters:")) {
                interface.setValue(request, forKey: "requestParameters")
            }
            interface.perform(NSSelectorFromString("activate"))
            let data = Data(ssid.utf8)
            let scanParameters = Self.scanParameters(types.scan, ssid: ssid)
            let selector = NSSelectorFromString("performScanWithParameters:error:")
            let scan = unsafeBitCast(interface.method(for: selector), to: Scan.self)
            var error: NSError?
            guard self.owns(operation), allowed() else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            let results = scan(interface, selector, scanParameters, &error) as? [NSObject] ?? []
            guard self.owns(operation), allowed() else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            let networks = results.filter {
                $0.responds(to: NSSelectorFromString("SSID")) && $0.responds(to: NSSelectorFromString("RSSI")) &&
                    $0.responds(to: NSSelectorFromString("isEAP")) &&
                    ($0.value(forKey: "SSID") as? Data) == data
            }.sorted {
                (($0.value(forKey: "RSSI") as? NSNumber)?.intValue ?? -200) >
                    (($1.value(forKey: "RSSI") as? NSNumber)?.intValue ?? -200)
            }
            var selected: (NSObject, NSObject)?
            if error == nil {
                for network in networks {
                    guard let known = interface.perform(NSSelectorFromString("knownNetworkProfileMatchingScanResult:"),
                        with: network)?.takeUnretainedValue() as? NSObject,
                        let profile = Self.profileForAssociation(known, ssid: data,
                            enterprise: network.value(forKey: "isEAP") as? Bool == true) else { continue }
                    selected = (network, profile)
                    break
                }
            }
            guard let (network, profile) = selected else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            let parameters = types.association.init()
            parameters.setValue(network, forKey: "scanResult")
            parameters.setValue(profile, forKey: "knownNetworkProfile")
            parameters.setValue(false, forKey: "rememberUponSuccessfulAssociation")
            parameters.setValue(false, forKey: "forceBSSID")
            // Leaving password/EAPCredentials nil selects the native saved-keychain path.
            let reply: Reply = { [weak self, weak operation] error in
                guard let self, let operation else { return }
                self.finish(operation, success: error == nil, allowed: allowed, completion: completion)
            }
            operation.parameters = parameters
            operation.reply = reply as AnyObject
            guard self.owns(operation), allowed() else {
                self.finish(operation, success: false, allowed: allowed, completion: completion); return
            }
            self.lock.withLock { operation.state.submitted = true }
            let associateSelector = NSSelectorFromString("associateWithParameters:reply:")
            let associate = unsafeBitCast(interface.method(for: associateSelector), to: Associate.self)
            associate(interface, associateSelector, parameters, operation.reply!)
        }
    }

    private func finish(_ operation: Operation, success: Bool, allowed: @escaping () -> Bool,
                        completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let result = self.lock.withLock { () -> (release: Bool, deliver: Bool) in
                guard self.current === operation else { return (false, false) }
                let deliver = operation.state.complete()
                let release = !operation.state.pending
                if release { self.current = nil }
                return (release, deliver)
            }
            if result.release { self.queue.async { self.invalidate(operation) } }
            if result.deliver && allowed() { completion(success) }
        }
    }

    private func invalidate(_ operation: Operation) {
        operation.interface.perform(NSSelectorFromString("invalidate"))
        operation.reply = nil
        operation.parameters = nil
    }

    static func scanParameters(_ type: NSObject.Type, ssid: String) -> NSObject {
        let parameters = type.init()
        // The scan request takes NSString; scan results and saved profiles use NSData.
        parameters.setValue(ssid, forKey: "SSID")
        parameters.setValue(true, forKey: "includeMatchingKnownNetworkProfiles")
        return parameters
    }

    /// Do not edit the actual saved profile or rebuild its EAP settings from partial information.
    static func profileForAssociation(_ profile: NSObject, ssid: Data, enterprise: Bool = false) -> NSObject? {
        guard profile.responds(to: NSSelectorFromString("SSID")),
              profile.value(forKey: "SSID") as? Data == ssid,
              let copying = profile as? NSCopying, let copy = copying.copy(with: nil) as? NSObject else { return nil }
        let raw = profile.responds(to: NSSelectorFromString("EAPProfile")) ? profile.value(forKey: "EAPProfile") : nil
        if enterprise || raw != nil {
            guard copy !== profile, copy.responds(to: NSSelectorFromString("setEAPProfile:")) else { return nil }
            guard raw == nil || raw is [String: Any] else { return nil }
            var eap = raw as? [String: Any] ?? [:]
            eap["DisableUserInteraction"] = true
            copy.setValue(eap, forKey: "EAPProfile")
        }
        return copy
    }
}
