# Native login-item startup

## Spec

Use `SMAppService.mainApp` for launch at login, retaining the existing settings app and small session worker. Do not register or kickstart the app executable as a LaunchAgent after migration. Stable certificate, canonical installation, settings/pairing, phone protocol, preferred Wi-Fi and FullWake/DarkWake rules remain unchanged. Settings close keeps the worker; Quit exits both. Native login launches hide Settings and leave the worker running. Manual launches still show Settings.

Migration: when the previously allowed legacy agent is enabled, asynchronously unregister it and register the main app, respecting FullWake and current system approval. Do not enable login for users who had it off/blocked. Closing or Quit waits for migration to settle. Unit tests must never enumerate/terminate the installed real app. Normal worker startup uses a child process and lifetime lock independently of login-item enablement.

## Evidence / ruling

Signed trials D/E, a 15-second settlement, root-preserving replacement, per-app LaunchServices refresh and pre-update legacy disable all still reproduced the first legacy-job CODESIGNING failure. None is accepted as a fix. Remove the timing workaround. Apple's native main-app login API launches the app at future logins without immediately bootstrapping a fixed executable LaunchAgent (`SMAppService.mainApp`, `register()` documentation). This directly removes the stale helper-job launch constraint from the update path. The owner already authorized autonomous standard native implementation and releases after real testing.

## Tasks

1. Simplify AgentModel around main-app registration and a normal session worker; migrate the old agent once. Keep bounded error reporting, close/Quit and power guards. Detect the native launched-as-login-item AppleEvent using SDK constants, hide Settings on login and close its observer after the worker is ready.
2. Replace tests for obsolete per-build agent re-registration with main-app registration, legacy consent/migration, hidden-login startup, child startup and lifecycle coverage. Verify tests leave the installed app running. Run focused review.
3. Two changed retained-key builds installed in place must each connect to the S23 with zero new crash reports. Check usable Wi-Fi, legacy job absent, mainApp login enabled, one canonical app, close/Quit. No merge/release before actual acceptance.
4. Update documentation, merge the owner fork, publish and upgrade through Homebrew. A real logout/reboot is disruptive and requires a separate owner test; don't claim it was performed.

## Implementation evidence

- The native path removes per-update fixed-agent registration, kickstart and arbitrary delays. Legacy migration preserves existing enabled intent only, waits removal completion and uses main-app login for future logins.
- Review identified a close-during-migration hole; the regression reproduced three failing assertions. Normal close now starts the replacement child and waits for fresh status carrying that child PID. Legacy snapshots cannot count as readiness; failure/deadline refuses the close instead of silently losing the worker.
- Native suite: 112 tests passed, including migration ownership/consent/power, hidden-login AppleEvent recognition, normal close/Quit and bounded child launch failures. Local tests left the installed app/phone connection running. Signed F/G and physical login remain unverified at this point.

- Scoped review found that a connected socket with no readiness snapshot bypassed the polling deadline. A deterministic blocked-watcher regression failed (113 tests, one failure). Deferred normal close now has its own generation-checked timeout; a stale timer cannot cancel a completed/new close. Timeout refuses termination and only reveals Settings in FullWake.
