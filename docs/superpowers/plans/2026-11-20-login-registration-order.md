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
