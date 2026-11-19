# Preferred Wi-Fi Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for native implementation and one final independent review.

**Goal:** Return a Mac from the S23 hotspot to selected saved Wi-Fi networks and shut the hotspot off only after verified handover.

**Architecture:** A small testable `WifiHandover` state machine coordinates asynchronous native operations through `WifiHandoverService`. `MacWifiHandoverService` supplies CoreWLAN scanning, macOS saved-network joins and a Wi-Fi-bound TLS connectivity check. Existing Agent maintenance and power generation own its lifecycle. A separate native Settings section owns preference editing and explicit Location permission requests.

**Tech Stack:** Swift, SwiftUI, CoreWLAN, CoreLocation, Network; no dependencies.

**Spec:** `docs/superpowers/specs/2026-11-19-preferred-wifi-design.md` (approved scope recorded there).

## Global Constraints

- Mac-only; no Android or BLE protocol changes.
- Default disabled and empty list. Exact SSIDs; credentials remain managed by macOS.
- Scan at most once per minute; three-second stable association; five-minute failed-network backoff.
- No work in sleep/DarkWake, automatic mode off or paused.
- Keep only `/Applications/Tetherbug.app`; compressed rollback artifacts only.

## Review Focus

- Stale completions after sleep, preferences changes, or a manual network change cannot join or switch off.
- A reachable endpoint through another network/VPN must not count as Wi-Fi handover.
- Captive portals, failed saved credentials and network loss preserve hotspot availability.
- The phone hotspot must never be a preferred candidate, including user-entered names.
- A timeout or denied Location permission must not cause a retry storm or modify existing automation.

### Task 1: Handover decisions and tests

**Files:** Create `macos/Sources/WifiHandover.swift`, `macos/Tests/WifiHandoverTests.swift`; update `macos/test.sh`, `macos/Tests/main.swift`.

**Interfaces:** `WifiHandoverService.scan`, `.join`, `.verifyInternet`, `.cancel`; `WifiHandover.Context` describes current Wi-Fi, hotspot readiness, preferences and wake/automatic permission. `WifiHandover.tick()` advances the state machine; `.cancel()` invalidates callbacks; `.busy` suppresses competing auto-on requests during handover.

- [ ] Write failing deterministic tests for discovery, ordered saved candidates, stable exact SSID + successful internet before Off, no-internet restoration, captive response, missing/denied permissions, list changes, manual network changes, rate limiting, failed-candidate backoff, manual pause, sleep and stale callbacks after wake.
- [ ] Run `bash macos/test.sh` and confirm the new feature is missing.
- [ ] Implement the state machine with injected clock, context, service and Off callback; no platform effects here.
- [ ] Run the whole Mac suite; expect zero failures. Commit the tested policy.

### Task 2: Native Wi-Fi service and Agent lifecycle

**Files:** Create `macos/Sources/MacWifi.swift`; update `macos/Sources/Agent.swift`, `macos/Sources/HotspotControl.swift`, `macos/Sources/Protocol.swift`, `macos/test.sh` and handover tests.

**Interfaces:** Native service receives `PowerActivity` and the existing scan queue. Agent context supplies current exact SSID, Wi-Fi path, active automatic policy and saved preferences. Optional `AgentState.wifiHandoverMessage` reports progress/failures without affecting older decoders.

- [ ] Test the connectivity-response parser (Apple success only, no redirects/captive/error/oversize) and active automatic policy (disabled/paused/expired).
- [ ] Run RED, then implement native scans, bounded/cancellable saved-network join and Wi-Fi-bound TLS probe. Check power generation before every effect and callback.
- [ ] Wire existing timer to handover; cancel before sleeping/quitting and on manual commands. Preserve existing hotspot cooldowns and avoid competing On commands while switching.
- [ ] Run the whole Mac suite and build native code; expect zero failures. Commit.

### Task 3: Settings, documentation and in-place local build

**Files:** Create `macos/Sources/WifiPreferencesView.swift`; modify `macos/Sources/App.swift`, `macos/build.sh`, `docs/macos.md`.

**Interfaces:** Persist `returnToPreferredWifi: Bool` and `preferredWifiNetworks: [String]`; Settings view uses the same defaults and explicit CoreLocation authorization. Include the Location usage description in the generated bundle.

- [ ] Implement native grouped Settings controls, explicit permission button, add/remove exact SSIDs and Add Current Network. Reject invalid/duplicate/hotspot entries. Follow existing SwiftUI ownership patterns.
- [ ] Document activation, saved-network prerequisite, TLS verification, pauses, battery-friendly scan interval and Mac-only scope.
- [ ] Run all tests; build arm64 and x86_64; inspect bundle metadata and signatures. Confirm Android diff is empty.
- [ ] Request one independent review of the whole branch, fix important findings with regression coverage, then install at the definitive path with a compressed rollback copy.
- [ ] Verify installed version, one actual app, managed startup and exposed Settings; report any permission or live Wi-Fi test requiring the user.
