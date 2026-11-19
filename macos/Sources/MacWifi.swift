import CoreLocation
import CoreWLAN
import Foundation
import Network

enum WifiAccess {
    static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways
    }

    static func savedNetworks(_ interface: CWInterface) -> Set<String> {
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return Set(profiles.compactMap(\.ssid))
    }
}

/// Main-queue owner of cancellable native operations. Blocking scans share the agent's scan queue.
/// Saved credentials stay inside macOS; networksetup asks its Wi-Fi service to join a known SSID.
final class MacWifiHandoverService: WifiHandoverService {
    private let activity: PowerActivity
    private let queue: DispatchQueue
    private let wifiInterface: () -> NWInterface?
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var process: Process?
    private var connection: NWConnection?
    private var timeout: DispatchWorkItem?
    private lazy var location = CLLocationManager()

    var locationAllowed: Bool { WifiAccess.authorized(location.authorizationStatus) }

    init(activity: PowerActivity, queue: DispatchQueue, wifiInterface: @escaping () -> NWInterface?) {
        self.activity = activity
        self.queue = queue
        self.wifiInterface = wifiInterface
    }

    func cancel() {
        lock.withLock { epoch &+= 1 }
        timeout?.cancel()
        timeout = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func begin() -> (UInt64, UInt64) {
        cancel()
        return (lock.withLock { epoch }, activity.generation)
    }

    private func allows(_ token: (UInt64, UInt64)) -> Bool {
        lock.withLock { epoch == token.0 } && activity.allows(token.1)
    }

    func scan(_ completion: @escaping (Set<String>) -> Void) {
        let token = begin()
        guard allows(token), locationAllowed else { completion([]); return }
        queue.async { [weak self] in
            guard let self, self.allows(token) else { return }
            guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
                DispatchQueue.main.async { if self.allows(token) { completion([]) } }
                return
            }
            let saved = WifiAccess.savedNetworks(interface)
            guard self.allows(token) else { return }
            let networks = (try? interface.scanForNetworks(withName: nil)) ?? []
            let names = Set(networks.compactMap(\.ssid)).intersection(saved)
            DispatchQueue.main.async {
                guard self.allows(token) else { return }
                completion(names)
            }
        }
    }

    func join(_ ssid: String, completion: @escaping (Bool) -> Void) {
        let token = begin()
        guard allows(token), locationAllowed, let interface = CWWiFiClient.shared().interface(),
              interface.powerOn(), WifiAccess.savedNetworks(interface).contains(ssid),
              let device = interface.interfaceName else { completion(false); return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        // Structured arguments preserve spaces, quotes and shell metacharacters in network names.
        // No password argument: only macOS's saved credentials may be used.
        child.arguments = ["-setairportnetwork", device, ssid]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        process = child
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.allows(token) else { return }
                self.timeout?.cancel()
                self.timeout = nil
                self.process = nil
                // The policy still requires the actual SSID, stable path and successful TLS probe.
                completion(child.terminationStatus == 0)
            }
        }
        guard allows(token) else { return }
        do { try child.run() }
        catch { process = nil; completion(false); return }
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.allows(token) else { return }
            self.cancel()
            completion(false)
        }
        timeout = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: expiry)
    }

    /// TLS authenticates the endpoint; requiring the Wi-Fi interface prevents Ethernet or a VPN
    /// from making an unusable candidate appear to work. No persistent connection or timer remains.
    func verifyInternet(_ completion: @escaping (Bool) -> Void) {
        let token = begin()
        guard allows(token), let interface = wifiInterface(),
              interface.name == CWWiFiClient.shared().interface()?.interfaceName else { completion(false); return }
        let parameters = NWParameters.tls
        parameters.requiredInterface = interface
        parameters.prohibitedInterfaceTypes = [.cellular, .wiredEthernet, .loopback, .other]
        let probe = NWConnection(host: "captive.apple.com", port: 443, using: parameters)
        connection = probe
        var finished = false
        let finish: (Bool) -> Void = { [weak self] success in
            guard let self, !finished, self.allows(token) else { return }
            finished = true
            self.timeout?.cancel()
            self.timeout = nil
            self.connection = nil
            probe.stateUpdateHandler = nil
            probe.cancel()
            completion(success)
        }
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /hotspot-detect.html HTTP/1.1\r\nHost: captive.apple.com\r\nConnection: close\r\n\r\n"
                probe.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    guard self.allows(token) else { return }
                    if error != nil { finish(false) }
                    else { self.receive(probe, token: token, data: Data(), finish: finish) }
                })
            case .failed: finish(false)
            default: break
            }
        }
        let expiry = DispatchWorkItem { finish(false) }
        timeout = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: expiry)
        probe.start(queue: .main)
    }

    private func receive(_ probe: NWConnection, token: (UInt64, UInt64), data: Data,
                         finish: @escaping (Bool) -> Void) {
        probe.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            guard let self, self.allows(token) else { return }
            var received = data
            if let chunk { received.append(chunk) }
            if received.count > 16_384 || error != nil { finish(false) }
            else if Self.isInternetSuccess(received) { finish(true) }
            else if complete { finish(false) }
            else { self.receive(probe, token: token, data: received, finish: finish) }
        }
    }

    static func isInternetSuccess(_ data: Data) -> Bool {
        guard data.count <= 16_384, let response = String(data: data, encoding: .utf8),
              let split = response.range(of: "\r\n\r\n") else { return false }
        let status = response.prefix(while: { $0 != "\r" }).split(separator: " ")
        guard status.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(status[0])), status[1] == "200" else { return false }
        let body = response[split.upperBound...].lowercased()
        return body.contains("<title>success</title>") && body.contains("<body>success</body>")
    }
}
