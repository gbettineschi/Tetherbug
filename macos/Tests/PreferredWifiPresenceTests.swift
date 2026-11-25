import Foundation

private final class PresenceScannerFake: WifiPresenceScanner {
    var pending = false
    var calls = 0
    var cancellations = 0
    var completion: ((Result<Set<Data>, Error>) -> Void)?
    func scan(_ completion: @escaping (Result<Set<Data>, Error>) -> Void) { calls += 1; self.completion = completion }
    func cancel() { cancellations += 1 }
    func found(_ names: [String]) { completion?(.success(Set(names.map { Data($0.utf8) }))) }
}

private final class PresenceFixture {
    var date = now
    var context = PreferredWifiPresence.Context(allowed: true, automaticActive: true,
        phoneReady: true, canTurnOff: true, hotspotOn: true, wifiDisconnected: false,
        wifiPoweredOn: true, locationAllowed: true, preferred: ["Home"], hotspotSSID: "Phone")
    let scanner = PresenceScannerFake()
    var offs = 0
    lazy var policy = PreferredWifiPresence(scanner: scanner, context: { self.context },
        now: { self.date }, turnOff: { self.offs += 1 })
}

func runPreferredWifiPresenceTests() {
    test("visible preferred Wi-Fi turns the hotspot off without joining or probing internet") {
        let f = PresenceFixture(); f.policy.tick(); f.scanner.found(["Home"])
        expect(f.offs == 1, "presence alone authorizes one Off")
        f.scanner.found(["Home"]); f.policy.tick()
        expect(f.offs == 1 && f.scanner.calls == 1, "a duplicate callback cannot send another command")
    }
    test("absent preferred Wi-Fi leaves the hotspot available") {
        let f = PresenceFixture(); f.policy.tick(); f.scanner.found(["Other"])
        expect(f.offs == 0, "an unrelated network is not a reason to turn Off")
    }
    test("automatic Off follows the master switch, pause, preference timer and courtesy") {
        for gate in 0..<8 {
            let f = PresenceFixture()
            switch gate {
            case 0: f.context.automaticActive = false
            case 1: f.context.preferHotspot = true
            case 2: f.context.courtesyElapsed = false
            case 3: f.context.allowed = false
            case 4: f.context.phoneReady = false
            case 5: f.context.wifiPoweredOn = false
            case 6: f.context.locationAllowed = false
            default: f.context.preferred = []
            }
            f.policy.tick()
            expect(f.scanner.calls == 0 && f.offs == 0, "ineligible policies never scan or send Off")
        }
    }
    test("a new gate or list change invalidates a scan even before the next tick") {
        for change in 0..<5 {
            let f = PresenceFixture(); f.policy.tick()
            switch change {
            case 0: f.context.allowed = false
            case 1: f.context.automaticActive = false
            case 2: f.context.preferHotspot = true
            case 3: f.context.preferred = ["Other"]
            default: f.context.courtesyElapsed = false
            }
            f.scanner.found(["Home"])
            expect(f.offs == 0, "fresh context wins over a queued result")
        }
    }
    test("sleep cancels and an old completion cannot act after wake") {
        let f = PresenceFixture(); f.policy.tick(); let old = f.scanner.completion
        f.context.allowed = false; f.policy.tick()
        f.context.allowed = true; f.policy.tick()
        old?(.success([Data("Home".utf8)]))
        expect(f.offs == 0, "awake generations cannot inherit stale results")
        f.scanner.found(["Home"])
        expect(f.offs == 1, "fresh discovery after wake works")
    }
    test("nearby preferred Wi-Fi prevents an automatic On Off loop") {
        let f = PresenceFixture(); f.context.wifiDisconnected = true
        f.policy.tick(); f.scanner.found(["Home"])
        f.context.hotspotOn = false; f.policy.tick()
        expect(f.policy.blocksAutomaticEnable, "keep the hotspot off while preferred presence is known")
        f.date += 60; f.policy.tick(); f.scanner.found(["Home"])
        expect(f.policy.blocksAutomaticEnable && f.offs == 1, "refresh presence without repeated Off commands")
        f.date += 60; f.policy.tick(); f.scanner.found([])
        expect(!f.policy.blocksAutomaticEnable, "leaving range restores ordinary activation")
    }
    test("disconnected activation waits for one bounded presence check") {
        let f = PresenceFixture(); f.context.hotspotOn = false; f.context.wifiDisconnected = true
        f.policy.tick()
        expect(f.policy.blocksAutomaticEnable, "do not request On before the first result")
        f.scanner.found([])
        expect(!f.policy.blocksAutomaticEnable, "an empty successful discovery allows On")
        f.date += 91; f.policy.tick()
        expect(f.policy.blocksAutomaticEnable, "expired observations do not authorize another On")
    }
    test("scan errors never send Off and do not strand disconnected activation") {
        let f = PresenceFixture(); f.context.wifiDisconnected = true
        f.policy.tick(); f.scanner.completion?(.failure(NSError(domain: NSPOSIXErrorDomain, code: 16)))
        expect(f.offs == 0 && !f.policy.blocksAutomaticEnable, "failure keeps the hotspot available")
        f.date += 59; f.policy.tick(); expect(f.scanner.calls == 1, "no busy retry loop")
        f.date += 1; f.policy.tick(); expect(f.scanner.calls == 2, "bounded retry is available")
    }
    test("a logical timeout preserves actual scan ownership and allows ordinary On") {
        let f = PresenceFixture(); f.context.wifiDisconnected = true
        f.policy.tick(); f.scanner.pending = true; let old = f.scanner.completion
        f.date += 15; f.policy.tick()
        expect(!f.policy.blocksAutomaticEnable && f.scanner.cancellations > 0, "bounded wait fails open for On")
        f.date += 60; f.policy.tick()
        expect(f.scanner.calls == 1, "never queue another scan behind a still-running OS call")
        old?(.success([Data("Home".utf8)])); expect(f.offs == 0, "timeout suppresses its late callback")
    }
    test("a scan left running across sleep cannot block activation forever") {
        let f = PresenceFixture(); f.scanner.pending = true; f.context.wifiDisconnected = true
        f.policy.tick(); f.date += 15; f.policy.tick()
        expect(f.scanner.calls == 0 && !f.policy.blocksAutomaticEnable, "bound waiting for an old radio call too")
    }
    test("connected Wi-Fi with the hotspot off does not cause periodic radio scans") {
        let f = PresenceFixture(); f.context.hotspotOn = false
        f.policy.tick(); f.date += 600; f.policy.tick()
        expect(f.scanner.calls == 0, "idle connected use adds no scanning")
    }
    test("the phone hotspot and canonically equivalent different SSID bytes cannot match") {
        let f = PresenceFixture(); f.context.preferred = ["Phone", "Caf\u{e9}"]
        f.policy.tick(); f.scanner.found(["Phone", "Cafe\u{301}"])
        expect(f.offs == 0, "exact raw preferred identity is required")
        f.date += 60; f.policy.tick(); f.scanner.found(["Caf\u{e9}"])
        expect(f.offs == 1, "the exact name qualifies")
    }
    test("a pending phone command cannot receive another Off") {
        let f = PresenceFixture(); f.policy.tick(); f.context.canTurnOff = false
        f.scanner.found(["Home"])
        expect(f.offs == 0, "phone command ownership wins")
    }
    test("a completion after its budget cannot send Off before the next timer tick") {
        let f = PresenceFixture(); f.context.wifiDisconnected = true
        f.policy.tick(); f.date += 16; f.scanner.found(["Home"])
        expect(f.offs == 0 && !f.policy.blocksAutomaticEnable, "enforce the deadline at callback delivery too")
    }
    test("an old completion cannot claim the next minute's scan") {
        let f = PresenceFixture(); f.policy.tick(); let old = f.scanner.completion
        f.scanner.found([]); f.date += 60; f.policy.tick()
        old?(.success([Data("Home".utf8)]))
        expect(f.offs == 0, "each scan has distinct ownership")
        f.scanner.found(["Home"]); expect(f.offs == 1, "only the current scan can act")
    }
}
