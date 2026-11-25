import Foundation

func runWifiDiagnosticsTests() {
    test("discovery results expire and cannot cross interfaces or awake generations") {
        let snapshot = WifiScanSnapshot(networks: ["observed"], interface: "en0", generation: 7, capturedAt: 100)
        expect(snapshot.results(interface: "en0", generation: 7, now: 110) == ["observed"], "reuse a recent observation")
        expect(snapshot.results(interface: "en0", generation: 7, now: 116) == nil, "do not reuse an expired observation")
        expect(snapshot.results(interface: "en1", generation: 7, now: 110) == nil, "scope the scan to its radio")
        expect(snapshot.results(interface: "en0", generation: 8, now: 110) == nil, "a wake invalidates old observations")
        expect(snapshot.results(interface: "en0", generation: 7, now: 99) == nil, "reject invalid clock ordering")
    }
    test("operation failures identify their stage without retaining sensitive error details") {
        do {
            _ = try WifiOperationFailure.perform(.directedScan) { () throws -> Int in
                throw NSError(domain: NSPOSIXErrorDomain, code: 16, userInfo: [NSLocalizedDescriptionKey: "test-secret"])
            }
            expect(false, "the operation must report failure")
        } catch let failure as WifiOperationFailure {
            expect(failure.stage == .directedScan && failure.domain == NSPOSIXErrorDomain && failure.code == 16, "preserve precise safe failure metadata")
            let encoded = String(decoding: try! JSONEncoder().encode(failure), as: UTF8.self)
            expect(!encoded.contains("test-secret"), "never expose localized description or userInfo")
        } catch { expect(false, "classify the failing operation") }
    }
    test("scan-only diagnosis stops after a discovery error") {
        let report = WifiScanDiagnostic.run(target: Data("Campus".utf8), allowed: { true }, scan: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: 16)
        })
        expect(report.steps.count == 1 && report.steps.first?.failure?.stage == .discoveryScan, "do not issue a second scan after the first failed")
        expect(!report.succeeded, "a failed scan is not an authenticated connection")
    }
    test("scan-only diagnosis probes the target only after discovering it") {
        let target = Data("Campus".utf8)
        let missing = WifiScanDiagnostic.run(target: target, allowed: { true }, scan: { _ in [Data("Other".utf8)] })
        expect(missing.steps.count == 1 && missing.steps[0].targetSeen == false, "do not probe an absent target")
        let seen = WifiScanDiagnostic.run(target: target, allowed: { true }, scan: { _ in [target] })
        expect(seen.steps.map(\.stage) == [.discoveryScan, .directedScan] && seen.succeeded, "the diagnostic is bounded to two read-only scan operations")
    }
    test("scan-only diagnosis rechecks the power gate between its two scans") {
        var awake = true
        let target = Data("Campus".utf8)
        let report = WifiScanDiagnostic.run(target: target, allowed: { awake }, scan: { _ in awake = false; return [target] })
        expect(report.steps.count == 1 && report.refusal == "not-permitted", "never start the next operation after sleep")
    }
}
