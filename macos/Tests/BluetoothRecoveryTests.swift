import Foundation

func runBluetoothRecoveryTests() {
    let phone = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let other = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    test("discovery rechecks for a phone that becomes available after launch") {
        var recovery = BluetoothRecovery()
        expect(recovery.due(poweredOn: true, now: now) == .discover, "initial discovery")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(1)) == nil, "no busy polling")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(5)) == .discover, "recheck system-connected phones")
        expect(recovery.beginConnection(to: phone, now: now.addingTimeInterval(5)), "a late phone can connect")
        recovery.connected(now: now.addingTimeInterval(6))
        expect(recovery.receivedStatus(from: phone), "fresh status establishes readiness")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(600)) == nil, "healthy connection needs no discovery")
    }

    test("stalled connection and GATT discovery are cancelled with retry backoff") {
        var recovery = BluetoothRecovery()
        expect(recovery.beginConnection(to: phone, now: now), "start connection")
        expect(!recovery.beginConnection(to: phone, now: now.addingTimeInterval(1)), "one connection request at a time")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(14)) == nil, "allow connection time")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(15)) == .resetConnection, "a pending connection cannot hang forever")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(16)) == nil, "retry waits")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(17)) == .discover, "first retry after two seconds")
        expect(recovery.beginConnection(to: phone, now: now.addingTimeInterval(17)), "retry can connect")
        recovery.connected(now: now.addingTimeInterval(18))
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(28)) == .resetConnection, "missing GATT status also has a deadline")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(31)) == nil, "second failure backs off longer")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(32)) == .discover, "second retry after four seconds")
    }

    test("Bluetooth return and wake resume discovery while preserving the known phone") {
        var recovery = BluetoothRecovery(preferred: phone)
        _ = recovery.beginConnection(to: phone, now: now)
        expect(recovery.due(poweredOn: false, now: now.addingTimeInterval(1)) == nil, "radio off performs no work")
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(2)) == .discover, "radio return immediately rediscovers")
        _ = recovery.beginConnection(to: phone, now: now.addingTimeInterval(2))
        _ = recovery.receivedStatus(from: phone)
        recovery.restart(now: now.addingTimeInterval(50))
        expect(recovery.due(poweredOn: true, now: now.addingTimeInterval(50)) == .discover, "wake refreshes a stale link")
        expect(recovery.preferred == phone, "remember the same phone across recovery")
        expect(!recovery.beginConnection(to: other, now: now.addingTimeInterval(50)), "do not replace the known phone with another advertiser")
    }

    test("only fresh status from the active phone establishes a preferred identity") {
        var recovery = BluetoothRecovery()
        _ = recovery.beginConnection(to: phone, now: now)
        expect(!recovery.receivedStatus(from: other), "ignore another peripheral's callback")
        expect(recovery.preferred == nil, "discovery alone does not establish a trusted preference")
        expect(recovery.receivedStatus(from: phone), "accept current phone status")
        expect(recovery.preferred == phone, "retain verified phone")
        recovery.disconnected(now: now.addingTimeInterval(1))
        expect(!recovery.accepts(other), "recovery retains the known identity")
    }
}
