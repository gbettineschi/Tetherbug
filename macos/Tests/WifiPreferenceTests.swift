import Foundation

func runWifiPreferenceTests() {
    test("upgrading preserves the preferred list, timer and existing courtesy deadline") {
        let (_, defaults) = environment()
        defaults.set(["Home"], forKey: "preferredWifiNetworks")
        defaults.set(now + 3600, forKey: "preferHotspotUntil")
        defaults.set(now + 300, forKey: "wifiSwitchNotBefore")
        let policy = WifiPreferenceControl(defaults: defaults)
        expect(policy.offNotBefore == now + 300 && policy.hotspotUntil == now + 3600, "migration preserves active intent")
        expect(defaults.stringArray(forKey: "preferredWifiNetworks") == ["Home"], "keep the configured networks")
        expect(defaults.object(forKey: "wifiSwitchNotBefore") == nil, "retire only the obsolete key")
    }
    test("repeat reports do not keep extending a native network-change courtesy") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Phone", now: now)
        policy.observeNetwork("Home", now: now + 1)
        policy.observeNetwork("Home", now: now + 100)
        expect(policy.offNotBefore == now + 301 && policy.canTurnOff(now: now + 301), "a single change creates one bounded delay")
    }
    test("native disconnection gives automatic Off a five-minute courtesy") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Campus", now: now)
        policy.observeNetwork(nil, disconnected: true, now: now + 1)
        expect(!policy.canTurnOff(now: now + 2), "explicit disconnection gives automatic Off a courtesy pause")
        policy.observeNetwork(nil, disconnected: true, now: now + 100)
        expect(policy.offNotBefore == now + 301, "a disconnected interval does not continually restart the pause")
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
        restarted.observeNetwork("Hotspot", now: now)
        restarted.observeNetwork("Campus", now: now + 20)
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
    test("native network changes delay automatic Off for five minutes") {
        let (_, defaults) = environment()
        let policy = WifiPreferenceControl(defaults: defaults)
        policy.observeNetwork("Hotspot", now: now)
        expect(policy.canTurnOff(now: now), "startup baseline does not invent a switch")
        policy.observeNetwork(nil, now: now + 1)
        policy.observeNetwork("Campus", now: now + 2)
        expect(!policy.canTurnOff(now: now + 301), "wait full five minutes after an external change")
        expect(policy.canTurnOff(now: now + 302), "eligible at expiry")
        policy.observeNetwork("Hotspot", now: now + 10)
        expect(policy.offNotBefore == now + 310, "reverse direction gets the same delay")
        policy.observeNetwork("Campus", now: now + 20)
        expect(policy.offNotBefore == now + 320, "replace the deadline, do not accumulate")
        expect(!WifiPreferenceControl(defaults: defaults).canTurnOff(now: now + 319), "restart cannot bypass it")
    }
}
