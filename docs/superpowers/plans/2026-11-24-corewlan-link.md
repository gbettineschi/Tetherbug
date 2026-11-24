# Public CoreWLAN and disconnected-only activation Implementation Plan

> **For agentic workers:** Execute inline with superpowers:executing-plans; use test-driven-development and a final independent review.

**Goal:** Restore public Wi-Fi joins and stop automatic hotspot activation for an associated but unusable Wi-Fi.

**Architecture:** Retain the handover state machine. Replace only its private association adapter with public CoreWLAN. Read physical-link association independently of NWPath internet/IP readiness.

**Tech Stack:** Swift, CoreWLAN, SystemConfiguration, Security; no new dependencies.

**Spec:** docs/superpowers/specs/2026-11-24-corewlan-link-design.md

## Global Constraints

- Preserve preferred Wi-Fi return and existing timing, sleep guards and user settings.
- Mac only; retain signing identity and one installed app.
- No credentials in logs or preferences; no credential/profile edits or trust bypasses.
- Do not claim live handover success from simulated tests.

## Review Focus

- A connected Wi-Fi without DHCP/internet must not trigger a hotspot request.
- Missing/unknown link data must not be treated as a confirmed disconnection.
- A timed-out synchronous association may still be running; no overlapping request after sleep/cancel.
- Enterprise credentials, identities and trust must use native public mechanisms for the exact saved SSID.
- A local join error must not be described as a failed internet test.

## Task 1: Public association adapter

Files: macos/Sources/NativeWifiAssociation.swift, macos/Tests/WifiHandoverTests.swift, macos/test.sh.

- [ ] Replace obsolete private-framework test expectations with tests for single-operation ownership, cancellation, stale completion, and public personal/enterprise selection; observe RED.
- [ ] Implement the public adapter with exact saved-network checks, directed CoreWLAN scan, scoped Keychain credentials and public association methods. Keep blocking work off the main thread; release ownership only when it returns.
- [ ] Run bash macos/test.sh; expect all tests green.
- [ ] Commit the adapter and tests.

## Task 2: Physical-link activation and useful errors

Files: macos/Sources/Agent.swift, macos/Sources/MacWifi.swift, macos/Sources/WifiHandover.swift, macos/Sources/App.swift, macos/Tests/WifiHandoverTests.swift, docs/macos.md.

- [ ] Add regressions for associated/no-internet, associated/no-DHCP, disconnected, Wi-Fi off and unknown link; observe RED.
- [ ] Read SystemConfiguration's physical-link status in the existing awake maintenance cycle. Require confirmed disconnection before automatic On; retain NWPath state for preferred-network settling and verification.
- [ ] Distinguish association versus internet-check failure and update settings/help text.
- [ ] Run bash macos/test.sh; expect all tests green.
- [ ] Commit, review the whole branch, build/sign with the retained certificate, install in place and verify launch/pairing/settings. Record any unperformed real-network test explicitly.

## Progress

- Clean baseline: 113 native Mac tests, zero failures.
- Reused the existing clean isolated worktree on codex/corewlan-wifi-state from main 8b81017; no new app copies or Android changes.
- Clarification received: retain preferred-network return; hotspot activation requires actual Wi-Fi disconnection.
