import Foundation

/// An awake generation owns every radio operation; sleep invalidates that ownership.
final class PowerActivity {
    enum Event { case startup, willSleep, didWake, workspaceWake, capabilitiesChanged }
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var running = false
    private var sleeping = false
    var generation: UInt64 { lock.withLock { epoch } }
    var active: Bool { lock.withLock { running } }
    private let capabilities: () -> UInt32?

    init(capabilities: @escaping () -> UInt32?) { self.capabilities = capabilities }
    static func isFullWake(_ capabilities: UInt32?) -> Bool {
        guard let capabilities else { return false }
        // IOPMCapabilityBits: CPU=1, Video=2, Audio=4. DarkWake lacks Audio/Video.
        return capabilities & 1 != 0 && capabilities & 6 != 0
    }

    func update(_ event: Event) {
        lock.withLock {
            if event == .willSleep { sleeping = true }
            // Only the ordered IOKit completion may clear the pre-sleep latch. Workspace
            // notifications can arrive late and are only an extra capability recheck.
            if event == .didWake { sleeping = false }
            let next = !sleeping && Self.isFullWake(capabilities())
            if next != running { epoch &+= 1; running = next }
        }
    }

    func allows(_ token: UInt64) -> Bool {
        lock.withLock { running && !sleeping && epoch == token && Self.isFullWake(capabilities()) }
    }
}
