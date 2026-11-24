import Foundation

func runWifiPreferenceTests() {
    test("leaving a bad Wi-Fi does not immediately retry the network the user left") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Campus", ownedTarget: nil, now: now)
        policy.observeNetwork(nil, ownedTarget: nil, disconnected: true, now: now + 1)
        expect(!policy.canSwitch(now: now + 2), "explicit disconnection gives preference switching a courtesy pause")
        policy.observeNetwork(nil, ownedTarget: nil, disconnected: true, now: now + 100)
        expect(policy.switchNotBefore == now + 301, "a disconnected interval does not continually restart the pause")
    }
    test("unavailable probes are not evidence that Wi-Fi internet is broken") {
        var date = now
        var callback: ((WifiInternetResult) -> Void)?
        var ons = 0
        let policy = HotspotInternetFallback(context: { .init(allowed: true, currentSSID: "Campus") },
            probe: { callback = $0 }, cancel: {}, enable: { ons += 1 }, now: { date })
        policy.tick(); date += 30; policy.tick(); callback?(.unavailable)
        date += 60; policy.tick(); callback?(.unavailable)
        expect(ons == 0, "zero actual probes cannot trigger cellular usage")
    }
    test("hotspot preference persists six hours and replaces rather than adds time") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.preferHotspot(for: .hours6, now: now)
        expect(policy.hotspotUntil == now + 6 * 3600, "six-hour deadline")
        policy.preferHotspot(for: .hour1, now: now + 10)
        expect(policy.hotspotUntil == now + 10 + 3600, "replacement starts now")
        let restarted = WifiPreferenceControl(defaults: defaults)
        expect(restarted.prefersHotspot(now: now + 100), "restart preserves intent")
        restarted.observeNetwork("Hotspot", ownedTarget: nil, now: now)
        restarted.observeNetwork("Campus", ownedTarget: nil, now: now + 20)
        expect(restarted.prefersHotspot(now: now + 20), "Wi-Fi return never cancels the explicit preference")
        restarted.refresh(now: now + 3610)
        expect(restarted.hotspotUntil == nil, "expiry clears the preference")
    }
    test("manual stop does not change Automatic Mode or its pause") {
        let (_, defaults) = environment()
        let auto = HotspotControl(defaults: defaults)
        auto.pauseAutomatic(for: .hour1, now: now)
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.preferHotspot(for: .hours6, now: now)
        policy.stopPreferringHotspot()
        expect(!policy.prefersHotspot(now: now), "explicit stop")
        expect(auto.pausedUntil == now + 3600 && auto.automatic, "independent preferences")
    }
    test("non-owned network changes delay both switch directions for five minutes") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Hotspot", ownedTarget: nil, now: now)
        expect(policy.canSwitch(now: now), "startup baseline does not invent a switch")
        policy.observeNetwork(nil, ownedTarget: nil, now: now + 1)
        policy.observeNetwork("Campus", ownedTarget: nil, now: now + 2)
        expect(!policy.canSwitch(now: now + 301), "wait full five minutes after an external change")
        expect(policy.canSwitch(now: now + 302), "eligible at expiry")
        policy.observeNetwork("Hotspot", ownedTarget: nil, now: now + 10)
        expect(policy.switchNotBefore == now + 310, "reverse direction gets the same delay")
        policy.observeNetwork("Campus", ownedTarget: nil, now: now + 20)
        expect(policy.switchNotBefore == now + 320, "replace the deadline, do not accumulate")
        expect(!WifiPreferenceControl(defaults: defaults).canSwitch(now: now + 319), "restart cannot bypass it")
    }
    test("owned associations and repeats do not start a courtesy cooldown") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Hotspot", ownedTarget: nil, now: now)
        policy.observeNetwork("Campus", ownedTarget: "Campus", now: now + 1)
        policy.observeNetwork("Campus", ownedTarget: nil, now: now + 2)
        expect(policy.canSwitch(now: now + 2), "the app's own successful handover is not a manual change")
    }
    test("unusable Wi-Fi fallback needs settled Wi-Fi and two failed probes") {
        var date = now
        var context = HotspotInternetFallback.Context(allowed: true, currentSSID: "Campus")
        var probes = 0
        var ons = 0
        var done: ((WifiInternetResult) -> Void)?
        let policy = HotspotInternetFallback(context: { context }, probe: { probes += 1; done = $0 },
            cancel: {}, enable: { ons += 1 }, now: { date })
        policy.tick()
        date += 29; policy.tick()
        expect(probes == 0, "give authentication and DHCP time")
        date += 1; policy.tick(); done?(.offline)
        expect(probes == 1 && ons == 0, "one failed request is not an outage")
        date += 14; policy.tick()
        expect(probes == 1, "space confirmation probes")
        date += 1; policy.tick(); done?(.offline)
        expect(ons == 1, "two failures trigger one request")
        date += 60; policy.tick()
        expect(probes == 2, "failed activation cannot storm")
        context.allowed = false
        date += 600; policy.tick()
        expect(ons == 1, "normal mode/off/paused/sleep never uses this fallback")
    }
    test("a network change or sleep invalidates a pending fallback probe") {
        var date = now
        var context = HotspotInternetFallback.Context(allowed: true, currentSSID: "Campus")
        var done: ((WifiInternetResult) -> Void)?
        var ons = 0
        var cancelled = 0
        let policy = HotspotInternetFallback(context: { context }, probe: { done = $0 },
            cancel: { cancelled += 1 }, enable: { ons += 1 }, now: { date })
        policy.tick(); date += 30; policy.tick()
        let stale = done
        context.allowed = false; policy.tick()
        stale?(.offline)
        expect(cancelled == 1 && ons == 0, "sleep cancels and suppresses callbacks")
        context.allowed = true; context.currentSSID = "Other"
        policy.tick(); date += 30; policy.tick(); done?(.offline)
        expect(ons == 0, "failures from another network never accumulate")
    }
}
