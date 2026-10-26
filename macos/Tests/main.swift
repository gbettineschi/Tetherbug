import Foundation

var failures = 0
var count = 0
var suites: [String] = []
let now = Date(timeIntervalSince1970: 1_800_000_000)

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { failures += 1; print("FAIL line \(line): \(message)") }
}

func test(_ name: String, _ body: () -> Void) {
    count += 1
    let before = failures
    body()
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}

func environment(automatic: Bool = true) -> (HotspotControl, UserDefaults) {
    let suite = "ie.xav.tetherbug.tests.\(UUID().uuidString)"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(automatic, forKey: "onNoWifi")
    return (HotspotControl(defaults: defaults), defaults)
}

func phoneState(_ hotspot: PhoneStatus.Hotspot = .off, controllable: Bool = true) -> AgentState {
    let value: UInt8 = [.off: 0, .starting: 1, .on: 2, .failed: 3][hotspot]!
    var state = AgentState()
    state.connected = true
    state.bluetooth = "on"
    state.phone = "Test S23"
    state.wifiOffline = true
    state.status = PhoneStatus(Data([3, value, 83, 4, controllable ? 1 : 0, 0, 0] + Array("Test hotspot".utf8)))!
    return state
}

test("manual mode toggles On and Off without creating a pause") {
    let (control, _) = environment(automatic: false)
    expect(control.toggle(phoneState(.off), now: now) == true, "Off → On")
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.on), now: now, receivedStatus: true)
    expect(control.toggle(phoneState(.on), now: now) == false, "On → Off")
    expect(control.pausedUntil == nil, "manual mode has no pause")
}

test("automatic Off pauses for 900 seconds and survives control recreation") {
    let (control, defaults) = environment()
    expect(control.toggle(phoneState(.on), now: now) == false, "request Off")
    expect(control.pausedUntil == now.addingTimeInterval(900), "15-minute expiry")
    let restarted = HotspotControl(defaults: defaults)
    expect(!restarted.shouldAutomaticallyEnable(phoneState(.off), now: now.addingTimeInterval(899)), "no activation before expiry")
    expect(restarted.shouldAutomaticallyEnable(phoneState(.off), now: now.addingTimeInterval(900)), "activation at expiry")
}

test("expired pause does not enable hotspot on working Wi-Fi") {
    let (control, defaults) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    let restarted = HotspotControl(defaults: defaults)
    var connectedWiFi = phoneState(.off)
    connectedWiFi.wifiOffline = false
    expect(!restarted.shouldAutomaticallyEnable(connectedWiFi, now: now.addingTimeInterval(901)), "working Wi-Fi wins")
    restarted.refresh(connectedWiFi, now: now.addingTimeInterval(901))
    expect(restarted.pausedUntil == nil, "expired deadline cleaned up")
}

test("manual On during a pause cancels it") {
    let (control, _) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.off), now: now, receivedStatus: true)
    expect(control.toggle(phoneState(.off), now: now.addingTimeInterval(10)) == true, "manual On bypasses pause")
    expect(control.pausedUntil == nil, "manual On resumes automatic mode")
}

test("changing automatic mode clears an old pause") {
    let (control, _) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    control.automatic = false
    expect(control.pausedUntil == nil, "disabling clears pause")
    expect(!control.shouldAutomaticallyEnable(phoneState(.off), now: now.addingTimeInterval(901)), "disabled stays disabled")
    control.automatic = true
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.off), now: now, receivedStatus: true)
    expect(control.shouldAutomaticallyEnable(phoneState(.off), now: now), "enabling resumes")
}

test("settings-window changes clear pause and are reflected by the policy") {
    let (control, defaults) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    defaults.set(false, forKey: "onNoWifi")
    control.refresh(phoneState(.off), now: now, receivedStatus: true)
    expect(!control.automatic, "external Auto setting is read")
    expect(control.pausedUntil == nil, "external change clears pause")
}

test("unknown, disconnected, Shizuku-unavailable and starting states reject toggles") {
    let (control, _) = environment()
    var disconnected = phoneState(.off)
    disconnected.connected = false
    for state in [AgentState(), disconnected, phoneState(.off, controllable: false), phoneState(.starting)] {
        expect(control.toggle(state, now: now) == nil, "unavailable command rejected")
        expect(!control.shouldAutomaticallyEnable(state, now: now), "Auto also waits for readiness")
    }
    expect(control.pausedUntil == nil, "rejected action cannot create a pause")
}

test("pending request blocks repeated clicks and automatic requests until phone confirms") {
    let (control, _) = environment()
    expect(control.toggle(phoneState(.off), now: now) == true, "first command accepted")
    expect(control.isPending, "await actual state")
    expect(control.toggle(phoneState(.off), now: now.addingTimeInterval(1)) == nil, "double click ignored")
    expect(!control.shouldAutomaticallyEnable(phoneState(.off), now: now.addingTimeInterval(1)), "no competing Auto request")
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.starting), now: now.addingTimeInterval(2), receivedStatus: true)
    expect(control.isPending, "starting is not success")
    control.refresh(phoneState(.on), now: now.addingTimeInterval(3), receivedStatus: true)
    expect(!control.isPending && control.error == nil, "actual On confirms success")
}

test("a request times out after 15 seconds without claiming success") {
    let (control, _) = environment()
    _ = control.toggle(phoneState(.off), now: now)
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.off), now: now.addingTimeInterval(14))
    expect(control.isPending, "still awaiting confirmation")
    control.refresh(phoneState(.off), now: now.addingTimeInterval(15))
    expect(!control.isPending && control.error != nil, "timeout exposes failure")
}

test("BLE error releases pending state and preserves the automatic pause") {
    let (control, _) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    control.writeCompleted(error: "Bluetooth write failed")
    expect(!control.isPending && control.error == "Bluetooth write failed", "write failure visible")
    expect(!control.shouldAutomaticallyEnable(phoneState(.off), now: now.addingTimeInterval(20)), "failed Off still honors user's pause")
}

test("disconnect and Shizuku loss fail an in-flight request") {
    for loseShizuku in [false, true] {
        let (control, _) = environment()
        _ = control.toggle(phoneState(.off), now: now)
        control.writeCompleted(error: nil)
        var state = phoneState(.off, controllable: !loseShizuku)
        state.connected = loseShizuku
        control.refresh(state, now: now.addingTimeInterval(1), receivedStatus: true)
        expect(!control.isPending && control.error != nil, "unavailable request ends with failure")
    }
}

test("a reported failure ends the request and allows an explicit retry") {
    let (control, _) = environment()
    _ = control.toggle(phoneState(.off), now: now)
    control.writeCompleted(error: nil)
    control.refresh(phoneState(.failed), now: now.addingTimeInterval(1), receivedStatus: true)
    expect(!control.isPending && control.error != nil, "reported failure")
    expect(control.toggle(phoneState(.failed), now: now.addingTimeInterval(2)) == true, "explicit retry")
    control.refresh(phoneState(.failed), now: now.addingTimeInterval(3))
    expect(control.isPending, "old failed snapshot must not fail a retry")
}

test("explicit resume cancels a persisted pause") {
    let (control, defaults) = environment()
    _ = control.toggle(phoneState(.on), now: now)
    let restarted = HotspotControl(defaults: defaults)
    restarted.resume()
    expect(restarted.shouldAutomaticallyEnable(phoneState(.off), now: now), "resume permits automatic activation")
}

test("idempotent CLI requests do not time out when the phone already reports the target state") {
    for on in [false, true] {
        let (control, _) = environment(automatic: false)
        let state = phoneState(on ? .on : .off)
        expect(control.beginRequest(on, state: state, now: now), "idempotent request accepted")
        expect(!control.writePending, "idempotent CLI request emits no transport write")
        control.refresh(state, now: now.addingTimeInterval(15))
        expect(!control.isPending && control.error == nil, "already-at-target is not a failed change")
    }
}

test("a phone report cannot allow a newer command before the prior Bluetooth write completes") {
    let (control, _) = environment(automatic: false)
    _ = control.toggle(phoneState(.off), now: now)
    control.refresh(phoneState(.on), now: now.addingTimeInterval(1), receivedStatus: true)
    expect(control.toggle(phoneState(.on), now: now.addingTimeInterval(2)) == nil,
           "no newer Off write while the earlier On callback is unresolved")
}

test("a delayed write error finishes only its own request before a newer one is accepted") {
    let (control, _) = environment(automatic: false)
    _ = control.toggle(phoneState(.off), now: now)
    control.refresh(phoneState(.on), now: now.addingTimeInterval(1), receivedStatus: true)
    control.writeCompleted(error: "Late On error")
    expect(control.error == "Late On error" && !control.isPending, "old callback ends the old operation")
    expect(control.toggle(phoneState(.on), now: now.addingTimeInterval(2)) == false, "new Off starts after callback")
    control.writeCompleted(error: nil)
    expect(control.isPending && control.error == nil, "new request still awaits its own phone report")
    control.refresh(phoneState(.off), now: now.addingTimeInterval(3), receivedStatus: true)
    expect(!control.isPending && control.error == nil, "new Off confirms normally")
}

test("an unresolved transport timeout requires reconnect before another write") {
    let (control, _) = environment(automatic: false)
    _ = control.toggle(phoneState(.off), now: now)
    control.refresh(phoneState(.off), now: now.addingTimeInterval(15))
    expect(control.needsReconnect && control.error != nil, "missing write callback requests connection reset")
    expect(control.toggle(phoneState(.off), now: now.addingTimeInterval(16)) == nil, "no overlapping retry")
    var disconnected = phoneState(.off)
    disconnected.connected = false
    control.refresh(disconnected, now: now.addingTimeInterval(17))
    expect(!control.writePending && !control.needsReconnect, "disconnect resets transport ownership")
    expect(control.toggle(phoneState(.off), now: now.addingTimeInterval(18)) == true, "fresh connection permits a new request")
}

runMenuBarTests()
runBluetoothRecoveryTests()
for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
print("\(count) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
