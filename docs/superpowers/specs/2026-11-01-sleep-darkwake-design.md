# Tetherbug sleep and DarkWake guard

Approved scope: Tetherbug must operate only in normal FullWake. There is no Keepresso integration. Lid position alone is irrelevant. Android, menu behavior and cooldowns stay unchanged.

Before acknowledging system sleep, invalidate queued work, cancel scans and connections, detach Bluetooth delegates, cancel the Wi-Fi path monitor and stop maintenance. Capability changes and wake notifications may restart the radio only after FullWake is confirmed. Unknown power state fails closed. Every asynchronous operation belongs to one awake generation; callbacks from older generations are discarded even after a later wake.

Use native IOKit sleep notifications, system-power capability notifications and an instantaneous capability query. CPU plus audio/video capabilities identify FullWake; display inactivity alone does not prohibit operation. Never create a sleep assertion or veto sleep.

A synchronous Wi-Fi scan already handed to macOS cannot be recalled. Sleep cleanup must not wait for it: discard its result and prohibit all following scans/retries. Hardware sleep/wake acceptance must be coordinated separately; do not suspend a Mac running other work.

Native references: Apple's `IOPMLib.h` documents non-abortable `SystemWillSleep`, prompt acknowledgement and `SystemHasPoweredOn`; [IOPMLibPrivate.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLibPrivate.h) documents capability bits, the instantaneous capability query and the dynamic-store key. The query is resolved at runtime and fails closed if unavailable. Local macOS currently reports `0x1f` and the store contains decimal `31`.

Physical acceptance, when the Mac is free: (1) FullWake connects normally; (2) start a connection/scan, sleep, confirm radio-suspended log before sleep; (3) leave asleep through maintenance wakes and confirm no radio-resumed log or new hotspot command; (4) ordinary wake reconnects using fresh status. No other application's power assertions are changed.
