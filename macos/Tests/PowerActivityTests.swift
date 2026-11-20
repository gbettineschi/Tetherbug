import Foundation

func runPowerActivityTests() {
    test("only CPU plus audio or video is FullWake; unknown fails closed") {
        for caps: UInt32? in [nil, 0, 1, 0x19, 8, 16] {
            expect(!PowerActivity.isFullWake(caps), "sleep/DarkWake/unknown cannot operate")
        }
        for caps: UInt32 in [3, 5, 0x1f] {
            expect(PowerActivity.isFullWake(caps), "normal wake, including display-off audio capability")
        }
    }
    test("startup in DarkWake or unknown never permits radio work") {
        for caps: UInt32? in [nil, 0x19] {
            let activity = PowerActivity(capabilities: { caps })
            activity.update(.startup)
            expect(!activity.active && !activity.allows(activity.generation), "fail closed")
        }
    }
    test("sleep cancels current work even before capabilities catch up") {
        let activity = PowerActivity(capabilities: { 0x1f })
        activity.update(.startup)
        let token = activity.generation
        expect(activity.allows(token), "normally awake")
        activity.update(.willSleep)
        activity.update(.capabilitiesChanged)
        expect(!activity.active && !activity.allows(token), "stale FullWake sample cannot reopen sleep latch")
    }
    test("a late Workspace wake cannot reopen the pre-sleep latch") {
        let activity = PowerActivity(capabilities: { 0x1f })
        activity.update(.startup)
        let token = activity.generation
        activity.update(.willSleep)
        activity.update(.workspaceWake)
        expect(!activity.active && !activity.allows(token), "independent Workspace event cannot override IOKit sleep")
        activity.update(.didWake)
        expect(activity.active && activity.allows(activity.generation), "IOKit completed FullWake resumes")
    }
    test("DarkWake does not reconnect; FullWake starts a fresh generation") {
        var caps: UInt32? = 0x1f
        let activity = PowerActivity(capabilities: { caps })
        activity.update(.startup)
        let old = activity.generation
        activity.update(.willSleep)
        caps = 0x19
        activity.update(.didWake)
        expect(!activity.active, "completed DarkWake still blocked")
        caps = 0x1f
        activity.update(.capabilitiesChanged)
        expect(activity.active && activity.allows(activity.generation), "promotion resumes")
        expect(!activity.allows(old), "old callback cannot act after a later FullWake")
    }
    test("capability reads reject work immediately, before the notification arrives") {
        var caps: UInt32? = 0x1f
        let activity = PowerActivity(capabilities: { caps })
        activity.update(.startup)
        let token = activity.generation
        caps = 0x19
        expect(!activity.allows(token), "background scans fail their immediate power check")
        activity.update(.capabilitiesChanged)
        expect(!activity.active, "native transition suspends")
        caps = 0x1f
        activity.update(.capabilitiesChanged)
        expect(activity.active && !activity.allows(token), "only new work may resume")
    }
    test("repeated FullWake events do not reset a live connection") {
        let activity = PowerActivity(capabilities: { 0x1f })
        activity.update(.startup)
        let token = activity.generation
        activity.update(.didWake)
        activity.update(.capabilitiesChanged)
        expect(activity.allows(token), "idempotent normal wake")
    }
    test("manual socket commands cannot send or queue requests in DarkWake") {
        for caps: UInt32? in [nil, 0x19] {
            let agent = Agent(capabilities: { caps })
            for command in ["enable", "disable", "toggle", "connect-hotspot"] {
                let state = agent.handle(command)
                expect(state?.lastRequest == nil, "no request created by \(command)")
                expect(state?.requestPending != true, "no command queued for later wake")
                expect(state?.connected != true, "no radio connection started")
            }
        }
    }
    test("an ordinary wake resumes after sleep without requiring a capability notification") {
        let activity = PowerActivity(capabilities: { 0x1f })
        activity.update(.startup)
        let old = activity.generation
        activity.update(.willSleep)
        activity.update(.didWake)
        expect(activity.active && activity.allows(activity.generation), "fresh FullWake")
        expect(!activity.allows(old), "pending pre-sleep operation remains invalid")
    }
}
