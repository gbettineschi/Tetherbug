import CoreServices
import Foundation
import Security
import ServiceManagement

/// Finishes one authorized re-registration before the caller starts or closes the helper.
final class LoginRegistration {
    private enum Phase { case idle, unregistering, settling, registering }
    private var phase = Phase.idle
    private var generation: UInt64 = 0
    private var wantsRegistration = true
    private var completion: ((Error?) -> Void)?
    private let status: () -> SMAppService.Status
    private let allowed: () -> Bool
    private let unregister: (@escaping (Error?) -> Void) -> Void
    private let register: () throws -> Void
    private let settle: (@escaping () -> Void) -> Void
    var inFlight: Bool { phase != .idle }

    init(status: @escaping () -> SMAppService.Status, allowed: @escaping () -> Bool,
         unregister: @escaping (@escaping (Error?) -> Void) -> Void,
         register: @escaping () throws -> Void,
         settle: @escaping (@escaping () -> Void) -> Void = LoginRegistration.settleNative) {
        self.status = status; self.allowed = allowed; self.unregister = unregister; self.register = register
        self.settle = settle
    }

    @discardableResult
    func begin(_ finished: @escaping (Error?) -> Void) -> Bool {
        guard !inFlight, allowed(), status() == .enabled else { return false }
        generation &+= 1
        let token = generation
        wantsRegistration = true
        phase = .unregistering
        completion = finished
        unregister { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.phase == .unregistering else { return }
                if !self.wantsRegistration { self.finish(CancellationError()); return }
                if let error, self.status() != .notRegistered { self.finish(error); return }
                self.phase = .settling
                self.settle { [weak self] in
                    guard let self, self.generation == token, self.phase == .settling else { return }
                    self.phase = .registering
                    self.resume()
                }
            }
        }
        return true
    }

    func resume() {
        guard phase == .registering, allowed() else { return }
        guard status() != .requiresApproval else {
            finish(NSError(domain: "Tetherbug.LoginRegistration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Allow Tetherbug in Login Items before restarting its service."]))
            return
        }
        do { try register(); finish(nil) } catch { finish(error) }
    }

    func cancel() {
        wantsRegistration = false
        // Keep ownership until the native unregister callback. Cancellation changes intent;
        // it does not prove that Service Management has finished removing the old job.
        if phase == .unregistering { return }
        if inFlight { finish(CancellationError()) }
    }

    private func finish(_ error: Error?) {
        phase = .idle
        let finished = completion
        completion = nil
        finished?(error)
    }

    static func unregisterNative(_ finished: @escaping (Error?) -> Void) {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else {
            finished(NSError(domain: "Tetherbug.LoginRegistration", code: 2)); return
        }
        let service = SMAppService.agent(plistName: loginAgentLabel + ".plist")
        guard service.status == .enabled else { finished(nil); return }
        let result = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        guard result == noErr else { finished(NSError(domain: NSOSStatusErrorDomain, code: Int(result))); return }
        // Apple guarantees that re-registration is safe after this completion, not merely
        // after the synchronous unregister submission returns.
        service.unregister(completionHandler: finished)
    }

    static func registerNative() throws {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else {
            throw NSError(domain: "Tetherbug.LoginRegistration", code: 2)
        }
        try SMAppService.agent(plistName: loginAgentLabel + ".plist").register()
    }

    static func settleNative(_ finished: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else { finished(); return }
        // This Mac's bundle/BTM record lagged unregister completion by about ten seconds.
        // Apple DTS recommends a delay when completion + a run-loop turn is insufficient:
        // https://developer.apple.com/forums/thread/783539 . Only a repair/update waits;
        // unchanged managed starts do not. The caller rechecks FullWake and approval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: finished)
    }

    static func runningBuild() -> String? {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else { return nil }
        var running: SecCode?
        var code: SecStaticCode?
        var raw: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
