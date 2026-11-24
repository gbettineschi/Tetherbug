import Foundation
import CoreWLAN

private final class HandoverServiceFake: WifiHandoverService {
    var scans = 0
    var joins: [String] = []
    var probes = 0
    var cancellations = 0
    var scanned: ((Set<String>) -> Void)?
    var joined: ((Bool) -> Void)?
    var verified: ((Bool) -> Void)?
    func scan(_ completion: @escaping (Set<String>) -> Void) { scans += 1; scanned = completion }
    func join(_ ssid: String, completion: @escaping (Bool) -> Void) { joins.append(ssid); joined = completion }
    func verifyInternet(_ completion: @escaping (Bool) -> Void) { probes += 1; verified = completion }
    func cancel() { cancellations += 1 }
}

private final class HandoverFixture {
    var date = now
    var context = WifiHandover.Context(allowed: true, enabled: true, automaticActive: true,
        preferred: ["Home", "EPFL"], currentSSID: "Test hotspot", wifiConnected: true,
        hotspotSSID: "Test hotspot", hotspotOn: true, canControlHotspot: true,
        wifiPoweredOn: true, locationAllowed: true)
    let service = HandoverServiceFake()
    var offs = 0
    lazy var handover = WifiHandover(service: service, context: { self.context },
        now: { self.date }, turnOff: { self.offs += 1 })
    func joined(_ ssid: String = "Home") {
        context.currentSSID = ssid
        context.wifiConnected = true
        service.joined?(true)
        handover.tick()
    }
    func settle() { date += 3; handover.tick() }
    func startJoin() { handover.tick(); service.scanned?(["Home", "EPFL"]) }
}

func runWifiHandoverTests() {
    test("public association selects enterprise authentication explicitly") {
        for security: CWSecurity in [.dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise] {
            expect(CoreWLANAssociation.authentication(supports: { $0 == security }) == .enterprise,
                   "enterprise variants must never use the personal-password path")
        }
        expect(CoreWLANAssociation.authentication(supports: { $0 == .wpa2Personal }) == .personal, "personal path")
        expect(CoreWLANAssociation.authentication(supports: { $0 == .none }) == .open, "open network needs no password")
        expect(CoreWLANAssociation.authentication(supports: { $0 == .owe }) == .open, "enhanced open needs no password")
    }
    test("sleep and timeout cannot overlap a still-running public association") {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "tetherbug.tests.association")
        let association = NativeWifiAssociation(queue: queue, perform: { _, _, allowed in
            expect(allowed(), "operation starts in the permitted generation")
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        })
        var firstDelivered = false
        association.join("Test", device: "test0", allowed: { true }) { _ in firstDelivered = true }
        expect(entered.wait(timeout: .now() + 1) == .success, "blocking operation starts")
        association.cancel(); association.suspend(); association.resumeAfterSleep()
        var rejected = false
        association.join("Other", device: "test0", allowed: { true }) { rejected = !$0 }
        expect(rejected && association.pending, "wake does not erase in-flight ownership")
        release.signal()
        let deadline = Date().addingTimeInterval(1)
        while association.pending && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(!association.pending && !firstDelivered, "actual completion clears ownership, suppressing the old callback")
    }
    test("a cancelled queued public join never touches the radio") {
        let queue = DispatchQueue(label: "tetherbug.tests.queued-association")
        queue.suspend()
        var calls = 0
        let association = NativeWifiAssociation(queue: queue, perform: { _, _, _ in calls += 1 })
        var delivered = false
        association.join("Test", device: "test0", allowed: { true }) { _ in delivered = true }
        association.suspend()
        queue.resume()
        let deadline = Date().addingTimeInterval(1)
        while association.pending && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(calls == 0 && !delivered && !association.pending, "sleep discards queued hardware work")
    }
    test("timed out native joins retain ownership until their blocking call returns") {
        var state = WifiAssociationState()
        state.submitted = true
        state.abandon()
        expect(state.pending && !state.canDeliver, "logical timeout cannot release in-flight hardware work")
        expect(!state.complete() && !state.pending, "the actual return releases ownership without a stale result")
        expect(!state.complete(), "a duplicate completion cannot deliver")
    }
    test("a public join returning during sleep releases ownership without delivering") {
        var state = WifiAssociationState()
        state.submitted = true
        state.abandon(forSleep: true)
        expect(state.pending, "sleep does not cancel a blocking CoreWLAN call")
        expect(!state.complete() && !state.pending, "actual return, unlike a cancellation ACK, releases ownership")
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
        expect(!receiver.ready, "handover waits for a full read after hotspot On")
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
    test("internet verification accepts only the expected successful Apple response") {
        let success = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
        expect(MacWifiHandoverService.isInternetSuccess(Data(success.utf8)), "expected HTML success")
        for response in ["HTTP/1.1 302 Found\r\n\r\n<BODY>Success</BODY>",
                         "HTTP/1.1 200 OK\r\n\r\nPlease sign in",
                         "HTTP/1.1 500 Error\r\n\r\n<TITLE>Success</TITLE><BODY>Success</BODY>",
                         "HTTP/1.1 200 OK\r\nX-Test: <BODY>Success</BODY>\r\n\r\nLogin"] {
            expect(!MacWifiHandoverService.isInternetSuccess(Data(response.utf8)), "redirect/captive/error/header spoof rejected")
        }
    }
    test("handover shares the existing automatic mode and timed pause policy") {
        let (control, _) = environment()
        expect(control.automaticActive(now: now), "default automatic enabled")
        control.pauseAutomatic(for: .minutes15, now: now)
        expect(!control.automaticActive(now: now), "pause suspends handover")
        expect(control.automaticActive(now: now + 900), "expiry resumes handover")
        control.automatic = false
        expect(!control.automaticActive(now: now + 900), "disabled mode stays disabled")
    }
    test("handover joins a listed network before verifying internet and sending Off") {
        let f = HandoverFixture()
        f.startJoin()
        expect(f.service.joins == ["Home"], "list order wins")
        expect(f.offs == 0 && f.handover.busy, "keep hotspot while joining")
        f.joined()
        expect(f.service.probes == 0, "wait for stability")
        f.settle()
        expect(f.service.probes == 1 && f.offs == 0, "probe after three seconds")
        f.service.verified?(true)
        expect(f.offs == 1, "only verified internet permits Off")
    }
    test("handover remains idle without opt-in, active automatic mode or usable phone") {
        for key in ["allowed", "enabled", "automaticActive", "wifiPoweredOn", "locationAllowed", "hotspotOn", "canControlHotspot", "empty"] {
            let f = HandoverFixture()
            switch key {
            case "allowed": f.context.allowed = false
            case "enabled": f.context.enabled = false
            case "automaticActive": f.context.automaticActive = false
            case "wifiPoweredOn": f.context.wifiPoweredOn = false
            case "locationAllowed": f.context.locationAllowed = false
            case "hotspotOn": f.context.hotspotOn = false
            case "canControlHotspot": f.context.canControlHotspot = false
            default: f.context.preferred = []
            }
            f.handover.tick()
            expect(f.service.scans == 0 && f.service.probes == 0 && f.offs == 0, "blocked by \(key)")
        }
    }
    test("an unrelated working Wi-Fi is never replaced") {
        let f = HandoverFixture()
        f.context.currentSSID = "Cafe"
        f.handover.tick()
        expect(f.service.scans == 0 && f.offs == 0, "leave the user's connection alone")
    }
    test("native auto-join to a preferred Wi-Fi also verifies before Off") {
        let f = HandoverFixture()
        f.context.currentSSID = "EPFL"
        f.handover.tick(); f.settle()
        expect(f.service.scans == 0 && f.service.joins.isEmpty && f.service.probes == 1, "no forced join")
        f.service.verified?(true)
        expect(f.offs == 1, "verified native connection shuts hotspot off")
    }
    test("a manually joined captive network is left available for portal sign-in") {
        let f = HandoverFixture()
        f.context.currentSSID = "EPFL"
        f.handover.tick(); f.settle(); f.service.verified?(false)
        expect(f.offs == 0 && f.service.joins.isEmpty, "no agent-owned join to undo")
        f.date += 60; f.handover.tick()
        expect(f.service.probes == 1, "failed native connection also backs off")
    }
    test("candidate loss during a probe restores an agent-owned hotspot connection") {
        for completionBeforeTick in [false, true] {
            let f = HandoverFixture()
            f.startJoin(); f.joined(); f.settle()
            f.context.currentSSID = nil
            f.context.wifiConnected = false
            if completionBeforeTick { f.service.verified?(true) } else { f.handover.tick() }
            expect(f.offs == 0 && f.service.joins.last == "Test hotspot", "restore on both event orders")
            f.context.currentSSID = "Test hotspot"; f.context.wifiConnected = true; f.service.joined?(true)
            f.date += 60; f.handover.tick(); f.service.scanned?(["Home"])
            expect(f.service.joins == ["Home", "Test hotspot"], "lost target also backs off")
        }
    }
    test("a new unrelated connection cancels pending joins and restorations") {
        for duringRestore in [false, true] {
            let f = HandoverFixture()
            f.startJoin()
            if duringRestore { f.joined(); f.settle(); f.service.verified?(false) }
            let pending = f.service.joined
            let cancellations = f.service.cancellations
            f.context.currentSSID = "Cafe"
            f.handover.tick()
            expect(f.service.cancellations > cancellations && !f.handover.busy, "cancel native request promptly")
            pending?(true)
            expect(!f.handover.busy && f.offs == 0, "late join completion cannot re-adopt connection")
        }
    }
    test("the phone hotspot is excluded even if listed first") {
        let f = HandoverFixture()
        f.context.preferred = ["Test hotspot", "Home"]
        f.handover.tick(); f.service.scanned?(["Test hotspot", "Home"])
        expect(f.service.joins == ["Home"] && f.service.probes == 0, "cannot verify the hotspot as its own replacement")
    }
    test("empty scans are limited to one per minute") {
        let f = HandoverFixture()
        f.handover.tick(); f.service.scanned?([])
        f.date += 59; f.handover.tick()
        expect(f.service.scans == 1, "no repeated scans")
        f.date += 1; f.handover.tick()
        expect(f.service.scans == 2, "next scan is due")
    }
    test("a failed connectivity check preserves hotspot and returns to it") {
        let f = HandoverFixture()
        f.startJoin(); f.joined(); f.settle(); f.service.verified?(false)
        expect(f.offs == 0 && f.service.joins == ["Home", "Test hotspot"], "restore without Off")
        f.context.currentSSID = "Test hotspot"; f.service.joined?(true)
        f.date += 60; f.handover.tick(); f.service.scanned?(["Home", "EPFL"])
        expect(f.service.joins.last == "EPFL", "failed candidate backs off while another may work")
    }
    test("a failed join never turns off the phone and backs off that network") {
        let f = HandoverFixture()
        f.startJoin(); f.service.joined?(false)
        expect(f.offs == 0 && f.service.joins == ["Home"], "still using hotspot; no restore necessary")
        f.date += 60; f.handover.tick(); f.service.scanned?(["Home"])
        expect(f.service.joins == ["Home"], "no retry during five minutes")
        f.date += 240; f.handover.tick(); f.service.scanned?(["Home"])
        expect(f.service.joins == ["Home", "Home"], "retry after backoff")
    }
    test("sleep cancels scanning and stale results cannot join after wake") {
        let f = HandoverFixture()
        f.handover.tick()
        let stale = f.service.scanned
        f.context.allowed = false; f.handover.tick()
        f.context.allowed = true
        stale?(["Home"])
        expect(f.service.joins.isEmpty && f.offs == 0, "pre-sleep scan lost ownership")
    }
    test("pause or preference changes cancel a pending internet result") {
        for change in ["pause", "preferences", "phone", "disabled"] {
            let f = HandoverFixture()
            f.startJoin(); f.joined(); f.settle()
            switch change {
            case "pause": f.context.automaticActive = false
            case "preferences": f.context.preferred = ["Other"]
            case "phone": f.context.hotspotSSID = "Another phone"
            default: f.context.enabled = false
            }
            f.service.verified?(true)
            expect(f.offs == 0, "completion rechecks \(change) even before next tick")
        }
    }
    test("manual network changes during scan or verification cannot be overridden") {
        let scan = HandoverFixture()
        scan.handover.tick(); scan.context.currentSSID = "Cafe"; scan.service.scanned?(["Home"])
        expect(scan.service.joins.isEmpty, "scan cannot override a new connection")
        let verify = HandoverFixture()
        verify.startJoin(); verify.joined(); verify.settle()
        verify.context.currentSSID = "Cafe"; verify.service.verified?(true)
        expect(verify.offs == 0, "internet belongs to exact preferred network")
    }
    test("losing the candidate during verification cannot shut off the hotspot") {
        let f = HandoverFixture()
        f.startJoin(); f.joined(); f.settle()
        f.context.wifiConnected = false; f.service.verified?(true)
        expect(f.offs == 0, "connected path must still be present")
    }
    test("enterprise Wi-Fi can finish authentication and DHCP after twenty seconds") {
        let f = HandoverFixture()
        f.startJoin(); f.service.joined?(true)
        f.context.currentSSID = "Home"; f.context.wifiConnected = false
        f.date += 25; f.handover.tick()
        expect(f.handover.busy && f.service.joins == ["Home"], "do not interrupt enterprise authentication")
        f.date += 40; f.context.wifiConnected = true; f.handover.tick(); f.settle()
        expect(f.service.probes == 1, "verify after the enterprise connection becomes usable")
        f.service.verified?(true)
        expect(f.offs == 1, "late successful connection permits Off")
    }
    test("a successful join without actual association times out safely") {
        let f = HandoverFixture()
        f.startJoin(); f.service.joined?(true)
        f.date += 91; f.handover.tick()
        expect(f.offs == 0 && !f.handover.busy, "bounded association wait")
    }
    test("a transient association cannot satisfy the stability interval") {
        let f = HandoverFixture()
        f.startJoin(); f.joined()
        f.date += 2; f.context.wifiConnected = false; f.handover.tick()
        f.date += 2; f.context.wifiConnected = true; f.handover.tick()
        f.date += 2; f.handover.tick()
        expect(f.service.probes == 0, "three continuous seconds required")
        f.date += 1; f.handover.tick()
        expect(f.service.probes == 1, "fresh stable interval completed")
    }
}
