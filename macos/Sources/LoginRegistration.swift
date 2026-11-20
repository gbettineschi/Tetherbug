import CoreServices
import Foundation
import ServiceManagement

/// Migrates an already-allowed legacy agent to native main-app login once.
final class LoginRegistration {
    private enum Phase { case idle, unregistering, registering }
    private var phase = Phase.idle
    private var generation: UInt64 = 0
    private var wantsRegistration = true
    private var completion: ((Error?) -> Void)?
    private let status: () -> SMAppService.Status
    private let allowed: () -> Bool
    private let unregister: (@escaping (Error?) -> Void) -> Void
    private let register: () throws -> Void
    var inFlight: Bool { phase != .idle }

    init(status: @escaping () -> SMAppService.Status, allowed: @escaping () -> Bool,
         unregister: @escaping (@escaping (Error?) -> Void) -> Void,
         register: @escaping () throws -> Void) {
        self.status = status; self.allowed = allowed; self.unregister = unregister; self.register = register
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
                self.phase = .registering
                self.resume()
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
        // Wait for the old job to be removed before preserving its intent as native app login.
        service.unregister(completionHandler: finished)
    }

    static func registerNative() throws {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else {
            throw NSError(domain: "Tetherbug.LoginRegistration", code: 2)
        }
        try SMAppService.mainApp.register()
    }

    static func legacyStatus() -> SMAppService.Status {
        guard Bundle.main.bundleIdentifier == "ie.xav.tetherbug" else { return .notRegistered }
        return SMAppService.agent(plistName: loginAgentLabel + ".plist").status
    }
}

/// The system marks a native login launch in its Open Application AppleEvent.
enum LoginLaunch {
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
