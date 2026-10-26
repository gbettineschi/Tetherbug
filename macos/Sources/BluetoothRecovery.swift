import Foundation

/// Deadlines are independent of CoreBluetooth callbacks: neither a pending connect nor missing
/// service discovery is guaranteed to fail on its own. The agent executes the returned actions.
struct BluetoothRecovery {
    enum Action { case discover, resetConnection }
    private(set) var preferred: UUID?
    private var active: UUID?
    private var ready = false
    private var deadline: Date?
    private var nextCheck = Date.distantPast
    private var nextAttempt = Date.distantPast
    private var backoff: TimeInterval = 2

    init(preferred: UUID? = nil) { self.preferred = preferred }

    func accepts(_ id: UUID) -> Bool { preferred == nil || preferred == id }

    mutating func beginConnection(to id: UUID, now: Date = Date()) -> Bool {
        guard accepts(id), !ready, deadline == nil, now >= nextAttempt else { return false }
        active = id
        deadline = now.addingTimeInterval(15)
        return true
    }

    mutating func connected(now: Date = Date()) {
        guard active != nil else { return }
        deadline = now.addingTimeInterval(10)
    }

    @discardableResult mutating func receivedStatus(from id: UUID) -> Bool {
        guard active == id, accepts(id) else { return false }
        preferred = id
        ready = true
        deadline = nil
        backoff = 2
        return true
    }

    mutating func disconnected(now: Date = Date()) {
        active = nil
        ready = false
        deadline = nil
        nextAttempt = now.addingTimeInterval(backoff)
        nextCheck = nextAttempt
        backoff = min(backoff * 2, 30)
    }

    mutating func restart(now: Date = Date()) {
        active = nil
        ready = false
        deadline = nil
        nextAttempt = now
        nextCheck = now
        backoff = 2
    }

    mutating func due(poweredOn: Bool, now: Date = Date()) -> Action? {
        guard poweredOn else { restart(now: now); return nil }
        guard !ready else { return nil }
        if let deadline {
            guard now >= deadline else { return nil }
            disconnected(now: now)
            return .resetConnection
        }
        guard now >= nextCheck else { return nil }
        nextCheck = now.addingTimeInterval(5)
        return .discover
    }
}
