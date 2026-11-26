import Foundation

func runWifiPreferenceTests() {
    test("upgrading drops the retired hotspot preference without changing Automatic Mode") {
        let (_, defaults) = environment()
        defaults.set(["Home"], forKey: "preferredWifiNetworks")
        defaults.set(now + 3600, forKey: "preferHotspotUntil")
        defaults.set(now + 300, forKey: "wifiSwitchNotBefore")
        defaults.set(true, forKey: "onNoWifi")
        defaults.set(now + 1800, forKey: "automaticPausedUntil")
        let policy = WifiPreferenceControl(defaults: defaults)
        expect(policy.offNotBefore == now + 300, "keep the existing network-change courtesy")
        expect(defaults.object(forKey: "preferHotspotUntil") == nil, "retired timers cannot keep suppressing the new rule")
        expect(defaults.stringArray(forKey: "preferredWifiNetworks") == ["Home"], "keep the configured networks")
        expect(defaults.bool(forKey: "onNoWifi") && defaults.object(forKey: "automaticPausedUntil") as? Date == now + 1800,
               "preserve the master's setting and deliberate pause")
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
