# Nearby hotspot shutdown cooldown implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement the approved final policy inline.

**Goal:** Pause automatic activation for 900 seconds after a fresh phone On-to-Off transition observed during one continuous Tetherbug Bluetooth connection. Losing Wi-Fi or moving away must not independently start the cooldown.

**Architecture:** Extend the existing HotspotControl fresh-status handling and persisted pause. Clear the On baseline on Bluetooth disconnection. Reuse the existing Android status notification; no Android protocol, behavior or UI change.

**Tech Stack:** Swift and the existing native Mac app.

**Spec:** User's revised request on 2026-10-27. The native Samsung unused-hotspot timeout has been found. The user explicitly approved that the existing Android status does not distinguish voluntary shutdown from native idle timeout: either starts the cooldown when received on a continuous nearby Bluetooth connection.

## Constraints and tests

- Preserve 900-second persistence and manual On cancellation.
- Fresh On-to-Off on a continuous link starts a cooldown; repeated Off does not extend it.
- Initial Off and Off first discovered after reconnection do not start a cooldown.
- Wi-Fi loss alone does not start a cooldown. No extra SSID reader or scan.
- Android behavior remains unchanged. Unified release uses version metadata 0.1.7/code107 to preserve Obtainium.

## Progress

- [x] Baseline: 36 Mac tests passed.
- [x] Earlier Wi-Fi-loss implementation was reviewed and tested, then superseded by the user's narrower request before any successful push or release.
- [x] Final-policy reconnection test reproduced two assertion failures, then passed after clearing the On baseline on disconnect.
- [x] Current native Mac suite: 41 tests, zero failures.
- [x] Preserved and merged four newer origin/main release-automation commits after the initial non-fast-forward push was rejected; no force push.
- [x] New release-source guard tests: 3 passed.
- [x] User approved nearby-connected shutdown, including native idle timeout.
- [x] Independent final-policy review: no blocking findings; 41 Mac tests and 3 source-publication tests passed.
- [x] Published source 5320bf3 and immutable v0.1.7; release workflow 40571481431 passed packaging, retained Android certificate checks and shared-tap publication.
- [x] Verified all four downloaded GitHub asset digests, ZIP checksums, universal Mac signature/architectures and APK identity 0.1.7/code107.
- [x] Shared tap commit b36c5da pins the published Mac ZIP; Homebrew installed 0.1.7 and the installed binary matches the release.
- [x] Running session helper connects to the S23 with Shizuku ready; Android device installation and settings were not changed.
- [ ] Complete per-app Gatekeeper approval and verify the launchd-managed login helper. The session helper works, but launchd rejected the new ad-hoc build with Launch Constraint Violation / EX_CONFIG. User approval for the app exception is pending; no security protection was bypassed.
