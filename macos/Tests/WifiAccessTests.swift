import Foundation
import CoreWLAN

private func finishScan(_ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !done(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

func runWifiAccessTests() {
    test("offline automatic activation waits for Bluetooth subscription and preferred discovery") {
        let (control, _) = environment()
        var metadata = PhoneStatusReceiver(), subscription = PhoneStatusSubscription()
        var s = phoneState(.off)
        s.wifiOffline = true
        _ = subscription.begin(now: now)
        _ = subscription.changed(notifying: false, failed: false)
        _ = metadata.receive(Data([3, 0, 80, 4, 1, 0, 0] + Array("Phone".utf8)), notification: false)
        _ = subscription.readCompleted()
        expect(!control.shouldAutomaticallyEnable(s, phoneReady: metadata.ready && subscription.ready, now: now),
               "the first read cannot enable before the subscribe ACK")
        _ = subscription.changed(notifying: true, failed: false)
        expect(control.shouldAutomaticallyEnable(s, phoneReady: metadata.ready && subscription.ready, now: now),
               "fully ready metadata may proceed to the presence gate")
    }
    test("unrelated saved profiles never cause a preferred-network radio scan") {
        var queries = 0
        let home = Data("Home".utf8), other = Data("Other".utf8)
        let absent = WifiDiscovery.discoverSaved([home], saved: [other]) { _ in queries += 1; return [home] }
        expect(queries == 0 && absent.isEmpty, "forgotten preferred networks are skipped before radio work")
        let present = WifiDiscovery.discoverSaved([home], saved: [home, other]) { candidates in
            queries += 1; expect(candidates == [home], "only qualifying configured identities reach discovery"); return [home]
        }
        expect(queries == 1 && present == [home], "saved preferred candidates can be discovered")
    }
    test("cancelled native discovery keeps ownership until the OS call returns") {
        let activity = PowerActivity(capabilities: { 0x1f }); activity.update(.startup)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var calls = 0, delivered = 0
        let scanner = MacWifiPresenceScanner(activity: activity, queue: DispatchQueue(label: "test.presence.owned"),
            authorized: { true }, perform: { _, _ in calls += 1; entered.signal(); release.wait(); return [] })
        scanner.scan([Data("Home".utf8)]) { _ in delivered += 1 }
        expect(entered.wait(timeout: .now() + 2) == .success && scanner.pending, "the real operation owns the scanner")
        scanner.cancel()
        scanner.scan([Data("Home".utf8)]) { _ in delivered += 1 }
        expect(calls == 1 && scanner.pending, "cancel does not permit another scan")
        release.signal(); finishScan { !scanner.pending }
        expect(!scanner.pending && delivered == 1, "only the immediate busy refusal is delivered")
    }
    test("cancelled queued discovery never invokes CoreWLAN") {
        let activity = PowerActivity(capabilities: { 0x1f }); activity.update(.startup)
        let queue = DispatchQueue(label: "test.presence.queued"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        var calls = 0, delivered = 0
        let scanner = MacWifiPresenceScanner(activity: activity, queue: queue, authorized: { true },
            perform: { _, _ in calls += 1; return [] })
        scanner.scan([Data("Home".utf8)]) { _ in delivered += 1 }; scanner.cancel(); gate.signal()
        finishScan { !scanner.pending }
        expect(calls == 0 && delivered == 0 && !scanner.pending, "invalidate work before it reaches the radio")
    }
    test("native discovery cannot deliver across sleep or request new permissions") {
        let activity = PowerActivity(capabilities: { 0x1f }); activity.update(.startup)
        var calls = 0, delivered = 0
        let denied = MacWifiPresenceScanner(activity: activity, queue: DispatchQueue(label: "test.presence.denied"),
            authorized: { false }, perform: { _, _ in calls += 1; return [] })
        denied.scan([Data("Home".utf8)]) { _ in delivered += 1 }
        expect(calls == 0 && delivered == 1, "no radio activity without an existing grant")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let scanner = MacWifiPresenceScanner(activity: activity, queue: DispatchQueue(label: "test.presence.sleep"),
            authorized: { true }, perform: { _, _ in entered.signal(); release.wait(); return [Data("Home".utf8)] })
        scanner.scan([Data("Home".utf8)]) { _ in delivered += 1 }
        expect(entered.wait(timeout: .now() + 2) == .success, "scan started awake")
        activity.update(.willSleep); release.signal(); finishScan { !scanner.pending }
        expect(delivered == 1 && !scanner.pending, "sleep discards the late result")
    }
    test("saved Wi-Fi security cannot downgrade to a same-name open access point") {
        let ssid = Data("Campus".utf8)
        expect(!WifiAccess.matches(savedSSID: ssid, security: .wpa2Enterprise,
            networkSSID: ssid, supports: { $0 == .none }), "open evil twin is rejected")
        expect(WifiAccess.matches(savedSSID: ssid, security: .wpa2Enterprise,
            networkSSID: ssid, supports: { $0 == .wpa2Enterprise }), "exact saved security is accepted")
        expect(!WifiAccess.matches(savedSSID: ssid, security: .wpa2Enterprise,
            networkSSID: Data("Other".utf8), supports: { _ in true }), "exact raw SSID is required")
    }
    test("an associated Wi-Fi without IP or internet never requests the hotspot") {
        expect(!WifiAccess.isDisconnected(poweredOn: true, linkActive: true), "physical association wins over path readiness")
        expect(WifiAccess.isDisconnected(poweredOn: true, linkActive: false), "confirmed disconnection can request hotspot")
        expect(!WifiAccess.isDisconnected(poweredOn: false, linkActive: false), "Wi-Fi disabled is not a request")
        expect(!WifiAccess.isDisconnected(poweredOn: true, linkActive: nil), "unknown state fails closed")
    }
    test("metadata subscription waits for unsubscribe, full read and subscribe acknowledgements") {
        var subscription = PhoneStatusSubscription()
        expect(subscription.begin(now: now) == .unsubscribe, "fence old bonded notifications first")
        expect(!subscription.acceptsValue && !subscription.ready, "ignore old values while stopping notifications")
        expect(subscription.changed(notifying: false, failed: false) == .read, "read only after unsubscribe ACK")
        expect(subscription.acceptsValue && !subscription.notification && !subscription.ready, "the full read is identifiable")
        expect(subscription.readCompleted() == .subscribe, "subscribe after the read")
        expect(!subscription.ready && !subscription.acceptsValue, "do not use an unacknowledged subscription")
        expect(subscription.changed(notifying: true, failed: false) == .read, "catch up transitions during the read/subscribe gap")
        expect(subscription.ready && subscription.notification, "now ordinary updates are accepted")
        expect(subscription.due(now: now + 60) == nil, "no timeout after enable ACK")
    }
    test("failed or stalled metadata subscriptions reset the connection") {
        for stage in ["unsubscribe", "read", "subscribe"] {
            var subscription = PhoneStatusSubscription()
            _ = subscription.begin(now: now)
            if stage != "unsubscribe" { _ = subscription.changed(notifying: false, failed: false) }
            if stage == "subscribe" { _ = subscription.readCompleted() }
            expect(subscription.due(now: now + 9) == nil, "not timed out yet")
            expect(subscription.due(now: now + 10) == .reconnect, "bounded \(stage)")
            expect(!subscription.ready && subscription.due(now: now + 20) == nil, "one recovery action")
        }
        var failed = PhoneStatusSubscription()
        _ = failed.begin(now: now)
        expect(failed.changed(notifying: false, failed: true) == .reconnect, "explicit subscription failure recovers immediately")
    }
    test("malformed metadata cannot mark the read or subscription ready") {
        var subscription = PhoneStatusSubscription()
        var receiver = PhoneStatusReceiver()
        _ = subscription.begin(now: now)
        _ = subscription.changed(notifying: false, failed: false)
        expect(receiver.receive(Data([255, 0]), notification: subscription.notification) == nil, "unsupported status rejected")
        expect(!receiver.ready && !subscription.ready, "no readiness from malformed data")
        expect(subscription.due(now: now + 10) == .reconnect, "read deadline still owns recovery")
    }
    test("short Bluetooth notifications preserve the full hotspot name from a read") {
        var receiver = PhoneStatusReceiver()
        let full = Data([3, 0, 80, 4, 1, 0, 0] + Array("Example phone's hotspot".utf8))
        _ = receiver.receive(full, notification: false)
        var short = Data(full.prefix(20))
        short[2] = 79
        let status = receiver.receive(short, notification: true)
        expect(status?.ssid == "Example phone's hotspot", "notification cannot truncate the saved name")
        expect(status?.battery == 79 && receiver.ready, "live fields still update without extra reads")
    }
    test("hotspot On refreshes metadata once and a resubscribe does not loop") {
        var receiver = PhoneStatusReceiver()
        let name = Array("Phone hotspot with long name".utf8)
        _ = receiver.receive(Data([3, 0, 80, 4, 1, 0, 0] + name), notification: false)
        let on = Data([3, 2, 80, 4, 1, 0x6c, 0x09] + name)
        _ = receiver.receive(Data(on.prefix(20)), notification: true)
        expect(!receiver.ready, "automation waits for a full read after hotspot On")
        _ = receiver.receive(on, notification: false)
        _ = receiver.receive(Data(on.prefix(20)), notification: true)
        expect(receiver.ready, "one refresh per transition, not per resubscribe")
    }
    test("a changed hotspot name is confirmed by a read, including a real 13-byte name") {
        var receiver = PhoneStatusReceiver()
        let prefix = "1234567890123"
        _ = receiver.receive(Data([3, 0, 80, 4, 1, 0, 0] + Array((prefix + " longer").utf8)), notification: false)
        let new = Data([3, 2, 80, 4, 1, 0, 0] + Array(prefix.utf8))
        _ = receiver.receive(new, notification: true)
        expect(!receiver.ready, "same-prefix renames wait for full metadata")
        expect(receiver.receive(new, notification: false)?.ssid == prefix && receiver.ready,
               "an actual short SSID is accepted from the read")
        let changed = Data([3, 2, 80, 4, 1, 0, 0] + Array("Other phone".utf8))
        _ = receiver.receive(changed, notification: true)
        expect(!receiver.ready, "a different prefix also requires a read")
    }
    test("truncated UTF-8 notifications cannot corrupt the confirmed hotspot name") {
        var receiver = PhoneStatusReceiver()
        let name = "123456789012é hotspot"
        let full = Data([3, 0, 80, 4, 1, 0, 0] + Array(name.utf8))
        _ = receiver.receive(full, notification: false)
        expect(receiver.receive(Data(full.prefix(20)), notification: true)?.ssid == name, "compare raw SSID bytes")
    }
    test("preferred network names preserve exact SSIDs and reject invalid entries") {
        expect(WifiNetworkNames.error(for: "", existing: [], hotspot: nil) != nil, "empty name rejected")
        expect(WifiNetworkNames.error(for: String(repeating: "é", count: 17), existing: [], hotspot: nil) != nil,
               "32-byte limit counts UTF-8 bytes")
        expect(WifiNetworkNames.error(for: "Home", existing: ["Home"], hotspot: nil) != nil, "duplicate rejected")
        expect(WifiNetworkNames.error(for: "Test hotspot", existing: [], hotspot: "Test hotspot") != nil, "phone rejected")
        expect(WifiNetworkNames.error(for: " Home ", existing: ["Home"], hotspot: nil) == nil, "SSID spaces are significant")
        expect(WifiNetworkNames.error(for: "home", existing: ["Home"], hotspot: nil) == nil, "SSID case is significant")
    }
}
