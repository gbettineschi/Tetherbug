import Foundation

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
    test("a successful join without actual association times out safely") {
        let f = HandoverFixture()
        f.startJoin(); f.service.joined?(true)
        f.date += 21; f.handover.tick()
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
