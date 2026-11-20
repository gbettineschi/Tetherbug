# Refresh updated login helpers before launching them

Evidence: all 23 recent Tetherbug crash reports are CODESIGNING / Launch Constraint Violation. Launchd's stored requirement contains the old cdhash. Current startup kickstarts it, then synchronously unregisters/registers, causing another rejected launch before delayed recovery. Apple DTS requires re-registering changed executables and waiting for unregister completion.

Use a small native registration coordinator: asynchronously unregister, then register after completion, with full-wake and current-consent checks. An actual running-code cdhash detects an updated build before any kickstart. Persist it after successful registration. Keep existing bounded recovery for unchanged builds. Closing or quitting waits for an in-flight registration to settle; explicit login disable invalidates it. No permission resets, crash-dialog suppression, Keepresso coupling or alternate app copies.

1. Add deterministic failing tests for update-before-kickstart ordering, delayed completion, consent revocation, sleep between phases and deferred close/quit. Use injected services only.
2. Implement coordinator/native completion API and wire AgentModel without touching actual services in tests. Run all Mac/release tests and focused review.
3. Build a retained-key signed trial, install in place, verify zero new CODESIGNING reports and a managed running helper. Recheck live phone status and native handover. Release only after both outstanding device checks pass.

## Implementation verification

- The update-order regression reproduced the old failure: 105 tests with three failing assertions. Native completion sequencing and proactive actual-cdhash refresh made the suite pass.
- Closing and Quit wait for native repair to settle; DarkWake defers registration until full wake, and revoked login consent is respected.
- Independent review found a cancellation-ownership race. Two more tests reproduced it (109 tests, four failures). Cancellation now retains the native unregister lease and resolves its completion; the Login Items control/handler cannot start another change while refresh is in flight.
- No real registration, Bluetooth, permission or power mutations are used in tests. A signed device update still must prove no new launch-constraint reports.

## Signed-device trial follow-up

Trial D (0.1.12-signing.4) still produced one launch-constraint report. The log confirms completed unregister at 15:26:46.298, re-registration against the old BTM UUID at 46.657, and a failed spawn at 46.688. LaunchServices changed its record around 15:26:56; the bounded second registration at 15:27:32 used a new BTM UUID and started correctly. Native completion sequencing is necessary but did not cover the observed cache propagation delay.

Apple DTS explicitly allows a delay when completion plus a main-run-loop turn is insufficient (https://developer.apple.com/forums/thread/783539). Add an asynchronous 15-second settlement between removal and re-registration, scoped to repairs/updated builds. Keep ownership, cancellation, consent and FullWake checks. This is an observed-device workaround, not an OS timing guarantee; require another changed signed build and zero new reports before release.

Test-isolation correction: the existing failed-socket Quit fallback enumerated actual NSRunningApplications even in the unbundled test host. Live Quit AppleEvents at 15:30:40 and 15:33:29 coincided with native test runs. Guard that native fallback by the real app bundle identity, matching native registration guards; tests may terminate only their injected child. Re-run with the real app open and verify its PID/phone connection survive.
