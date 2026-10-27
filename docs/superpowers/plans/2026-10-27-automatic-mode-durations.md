# Automatic mode duration controls

**Goal:** Ship the user-approved Mac automatic-mode controls as 0.1.8 and update through the shared Homebrew tap. The user accepted the local trial and requested restoring Indefinitely before publication.

**Design:** Keep the existing Settings `onNoWifi` switch and persisted timed-suspension deadline. Both menu entries remain available when automatic mode is off, including if disabled in Settings. Clicking active Automatic Mode disables it without a deadline or expiry label; clicking suspended or disabled Automatic Mode enables/resumes it. The submenu offers 15 minutes, 30 minutes, 1 hour, 2 hours, 3 hours, Today and Indefinitely. Indefinitely disables the existing automatic-mode setting with no deadline, exactly like a plain Automatic Mode Off click. Finite choices replace the deadline and schedule resumption even from Settings Off. Today ends at the next local midnight. Manual hotspot On cancels a timed suspension but does not re-enable disabled automatic mode. An earlier local trial's indefinite suspension migrates to disabled automatic mode. The user withdrew the original paragraph about greying out both entries and cancelling the pause on disable. The native checkmark gutter remains reserved in both states.

**Implementation:** Extend HotspotControl and AgentState, connect the existing agent callbacks to a native NSMenu submenu, and keep the current one-second maintenance timer. No Android changes, new dependency, notification or extra process.

## Steps

- [x] Add failing policy tests for 300-second automatic cooldowns, selected durations, replacement, midnight/DST, persistence and resuming from Settings Off.
- [x] Add failing menu tests for effective checkmarks, wording, all submenu actions and controls remaining available while off.
- [x] Implement the policy and agent/menu wiring; update Settings wording and the existing preview.
- [x] Run Mac tests, review the diff independently, build and verify the local app.
- [x] Back up the installed app/preferences, install the local trial and verify the helper and live status. Native menu actions/checkmarks/disabled state were verified by the AppKit test harness; visual acceptance of the installed dropdown is left to the user.
- [x] User tested the local builds and approved shipping after restoring Indefinitely.
- [ ] Merge/push the verified source, publish 0.1.8 through the existing tag workflow, verify assets and automatic tap update.
- [ ] Install the published Mac release through Homebrew and verify the login helper and phone connection.

## Local trial verification (2026-10-27)

- Baseline: 41 passing tests. Updated existing assertions first produced nine expected failures for the old 15-minute policy/checkmark/wording; final suite passes all 50 tests.
- Independent review found no blocking issue; `git diff --check` passes.
- Universal arm64/x86_64 build installed at `/Applications/Tetherbug.app`, version `0.1.8-local.1`; strict code-signature verification succeeds. Installed binary SHA-256 matches the build: `8ea69fbe5d1747ac5ffdf204952d171ee25d0f8c6e4caa63b3113297a7bae6e1`.
- Previous app and private preferences backed up under ignored `build/deployment-backups/0.1.8-local.1/`.
- Existing ad-hoc login registration initially failed with EX_CONFIG. Unregistering, quitting, reopening from Finder and registering again restored the real launchd-owned helper (PID 7146, PPID 1, run count 1, no prior exit). No security exception or quarantine removal was used.
- After Settings closed, the helper remains connected to the S23, Shizuku is controllable, no request is pending, master automatic activation remains on and no suspension is set. No phone hotspot toggle was needed during installation.
- Homebrew receipt and public release remain 0.1.7; this is a local trial only. No Android changes, push, merge, tag or release.

### Corrected local trial after user clarification

The user withdrew the entire paragraph about greying both entries and clearing a pause on disable. Menu actions now remain available while automatic mode is off, including from Settings Off. Resume enables the existing setting and clears suspension; choosing a duration enables scheduled activation and replaces the previous suspension. The pre-existing Settings-toggle behavior is otherwise unchanged.

- Updated tests first failed on the old guards; all 51 tests now pass. Independent delta review found no regression; `git diff --check` passes.
- Universal `0.1.8-local.2` installed and strict signature verification passed. Installed binary matches the local build: SHA-256 `a5691b717f3a92b8290c0989d63eaaac6d5233396f033f37772dc4cd5d26baf6`.
- Previous trial and private preferences preserved in ignored `build/deployment-backups/0.1.8-local.2/`.
- Re-registering after a Finder relaunch restored the real login helper, PID 11194, parent 1, run count 1 and no prior exit. Connected S23 reports Shizuku controllable, no pending command, automatic mode enabled and no suspension. Settings closed, leaving the helper active for the user's trial.
- No Android changes, push, merge, tag, release or Brew update. User acceptance is still required before publication.

### Local trial 3: direct disable, timed submenu only

User removed the Indefinitely submenu entry and changed the plain Automatic Mode click to disable without a deadline. The menu now offers only the six finite durations. Direct disable uses the existing automatic-mode setting, so it persists across restart and manual hotspot On does not reactivate automatic mode. Legacy indefinite suspension from earlier local trials migrates to mode Off, with no expiry. Timed suspension/resume behavior is otherwise unchanged.

- Updated behavior tests failed against the previous implementation; all 51 tests pass after the correction. Independent delta review found no regression.
- Universal `0.1.8-local.3` installed, signature verification passed, and installed binary matches the build: SHA-256 `aca6c121095182f9942ae2de5589593c5925f64549d510a45fcff02021a985c9`.
- Previous trial and private preferences backed up in ignored `build/deployment-backups/0.1.8-local.3/`.
- Re-registration after relaunch restored launchd helper PID 14678 (parent 1, first run, no prior exit), version `0.1.8-local.3`. S23 is connected and controllable, no command pending. Settings closed, leaving the helper active.
- Publication and Homebrew remain unchanged pending user acceptance. No Android changes.

### Local trial 4: stable native checkmark gutter

User requested that command labels keep the same margin when the Auto checkmark changes. A native AppKit measurement reproduced Off width 211 / On width 225 even with `showsStateColumn=true`. A transparent off-state image with the built-in checkmark's size reserves the native state column in both states (isolated probe 230 / 230), leaving AppKit's On image and accessibility state unchanged. The regression test measures the real command rows without the wide header/minimum width masking the change: it failed before the fix, and the full suite now passes 52 tests. Independent review found no issue.

- Installed universal `0.1.8-local.4`; strict signature check passes. Installed/build binary SHA-256 match: `48d27faaa2e8c962ae364a4d4f1bac7baa0e7804336d53c06f0140de0c91f28c`.
- Previous trial/private preferences backed up under ignored `build/deployment-backups/0.1.8-local.4/`.
- During registration the helper initially failed the OS signing launch constraint and the fallback reported Bluetooth unknown. TCC logs specifically showed a Bluetooth code-requirement mismatch and a new prompt. After Bluetooth became available, unregister/register restored the real login helper (PID 19549, parent 1, first run, no prior exit). These observations do not establish that TCC was the sole cause of the launch-constraint failure. No quarantine removal or global security change was used.
- After Settings closed, helper remains connected to the S23 with Shizuku controllable and no pending request. Visual acceptance of the installed dropdown is left to the user.
- No push, merge, tag, release, Homebrew update or Android change. Publication still waits for the user's OK.

## Review focus

- A short automatic cooldown must not shorten a longer explicit suspension or re-enable disabled automatic mode.
- Expired/recreated state must resume automatically only when the master and Wi-Fi conditions allow it.
- Today uses the next local midnight, including daylight-saving changes.
- Both menu entries must remain usable while automatic mode is off or suspended, and be disabled only during app shutdown.
- The existing stable status icon and one-helper ownership must remain unchanged.
