# Sleep and DarkWake implementation

Spec: `docs/superpowers/specs/2026-11-01-sleep-darkwake-design.md`.
Implement inline in the isolated `codex/macos-sleep-darkwake` checkout. No push, merge or release.

### Task 1: Power lifecycle and cancellation

1. Write meaningful failing tests for FullWake/DarkWake/unknown classification, sleep latch, generation invalidation, normal wake recovery and rejected manual commands.
2. Implement a thread-safe power activity gate and native power monitor. Integrate the gate with Agent lifecycle, generation-stamped Bluetooth delegates, timers, path updates and Wi-Fi scan loops/fallbacks.
3. Run `bash macos/test.sh`. Expected: all existing and new tests pass. Build a universal local app. Expected: arm64 and x86_64 compilation and ad-hoc signing succeed.
4. Commit source, tests and documentation locally after verification.

### Task 2: Review and local delivery

1. Obtain a fresh whole-change review. Review focus: native notification acknowledgement; startup in DarkWake; DarkWake-to-FullWake promotion; stale callback ownership; asynchronous scan cancellation; no sleep assertions or Keepresso coupling.
2. Fix important findings with regression tests, run the full suite and build again if changed.
3. Back up the installed app and install/restart the local build without changing phone settings or suspending the Mac. Verify the live agent can reconnect while FullWake. Record remaining physical acceptance checks.

## Review Focus

Unit tests do not exercise physical Bluetooth, macOS sleep notification delivery or already executing CoreWLAN calls. Inspect all callback entry points, cross-queue generation checks, resource teardown and whether any timer or reconnect survives sleep. Verify that power-state reads cannot reopen the pre-sleep latch and that fresh FullWake resumes without replaying pending hotspot commands.
