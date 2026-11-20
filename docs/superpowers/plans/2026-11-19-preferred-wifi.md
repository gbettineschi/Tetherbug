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

- [x] Write failing deterministic tests for discovery, ordered saved candidates, stable exact SSID + successful internet before Off, no-internet restoration, captive response, missing/denied permissions, list changes, manual network changes, rate limiting, failed-candidate backoff, manual pause, sleep and stale callbacks after wake.
- [x] Run `bash macos/test.sh` and confirm the new feature is missing.
- [x] Implement the state machine with injected clock, context, service and Off callback; no platform effects here.
- [x] Run the whole Mac suite; expect zero failures. Commit the tested policy.

### Task 2: Native Wi-Fi service and Agent lifecycle

**Files:** Create `macos/Sources/MacWifi.swift`; update `macos/Sources/Agent.swift`, `macos/Sources/HotspotControl.swift`, `macos/Sources/Protocol.swift`, `macos/test.sh` and handover tests.

**Interfaces:** Native service receives `PowerActivity` and the existing scan queue. Agent context supplies current exact SSID, Wi-Fi path, active automatic policy and saved preferences. Optional `AgentState.wifiHandoverMessage` reports progress/failures without affecting older decoders.

- [x] Test the connectivity-response parser (Apple success only, no redirects/captive/error/oversize) and active automatic policy (disabled/paused/expired).
- [x] Run RED, then implement native scans, bounded/cancellable saved-network join and Wi-Fi-bound TLS probe. Check power generation before every effect and callback.
- [x] Wire existing timer to handover; cancel before sleeping/quitting and on manual commands. Preserve existing hotspot cooldowns and avoid competing On commands while switching.
- [x] Run the whole Mac suite and build native code; expect zero failures. Commit.

### Task 3: Settings, documentation and in-place local build

**Files:** Create `macos/Sources/WifiPreferencesView.swift`; modify `macos/Sources/App.swift`, `macos/build.sh`, `docs/macos.md`.

**Interfaces:** Persist `returnToPreferredWifi: Bool` and `preferredWifiNetworks: [String]`; Settings view uses the same defaults and explicit CoreLocation authorization. Include the Location usage description in the generated bundle.

- [x] Implement native grouped Settings controls, explicit permission button, add/remove exact SSIDs and Add Current Network. Reject invalid/duplicate/hotspot entries. Follow existing SwiftUI ownership patterns.
- [x] Document activation, saved-network prerequisite, TLS verification, pauses, battery-friendly scan interval and Mac-only scope.
- [x] Run all tests; build arm64 and x86_64; inspect bundle metadata and signatures. Confirm Android diff is empty.
- [x] Request one independent review of the whole branch, fix important findings with regression coverage, then install at the definitive path with a compressed rollback copy.
- [ ] Verify the Settings screen and full saved-network handover after the Mac is unlocked and networks are selected. Installed version, single actual app and managed startup are verified.


## Implementation evidence — 2026-11-19

- Baseline: 67 Mac tests, zero failures. Initial handover suite: 81; native/validation suite: 84.
- Independent review: three important policy cases reproduced with eight failing assertions. Added ownership for agent-initiated joins, restoration/backoff after target loss, and cancellation when another network is selected. Final suite: **87 tests, zero failures**.
- Review scope fixes: connectivity probe binds to the exact `NWInterface` matching CoreWLAN, and disabled/paused/ineligible handover avoids hardware identity reads.
- Universal arm64/x86_64 build, strict ad-hoc signature verification and bundle property-list validation passed.
- A standalone invocation of the actual native connectivity service on this Mac passed its TLS check over the exact Wi-Fi adapter. No Wi-Fi change was made during this diagnostic.
- Installed `0.1.12-wifi.1` at `/Applications/Tetherbug.app`; compressed 0.1.11 rollback retained under ignored `build/`. Spotlight lists one actual installed bundle. Existing managed login worker recovered automatically after signature-registration refresh and is running the new version.
- Android diff is empty. Feature remains disabled and list empty.
- UI verification is blocked by the locked Mac. Native saved-credential/enterprise joins, Location permission attribution between window and worker, VPN configurations, and cancellation of an OS join already submitted still require a real handover test. No release is published as part of this implementation.


## Live-test follow-up

- The existing-network path passed on the actual paired phone: the agent verified the selected home Wi-Fi over TLS, requested hotspot Off, and received the phone's Off confirmation.
- The switch test exposed truncated Bluetooth status notifications: a 20-byte notification contains only 13 SSID bytes after the v3 header. Reconnecting and doing a full characteristic read returned the correct complete name. The short name caused an attempted join to a nonexistent SSID.
- Added Mac-only full-metadata reception and an acknowledged unsubscribe/read/subscribe sequence, including a catch-up read after resubscribing. Preserve complete names across partial UTF-8 notifications. Reject malformed reads before marking the connection ready; subscription failures and timeouts use existing reconnection recovery. Seven regression tests bring the suite to 94 passing tests.
- The corrected universal build is installed in place as 0.1.12-wifi.3. The Mac locked again during preparation; final bonded reconnect and hotspot-to-preferred-Wi-Fi switching remain pending unlock. Publishing remains conditional on the real switch passing.


## Enterprise-network timing follow-up

- The corrected build connected the Mac to the actual phone hotspot, discovered the selected campus Wi-Fi and joined it using macOS's stored credentials. The gateway changed away from the campus network and subsequently returned, confirming a real network switch.
- Campus authentication/DHCP finished after the original 20-second settling deadline. The safety behaviour worked: the app kept the hotspot on instead of claiming successful internet access. Extend the bounded association wait to 90 seconds and cover a connection becoming usable after 65 seconds with a failing-then-passing regression.
- Suite now passes 95 Mac tests plus three release-source guard tests. The universal 0.1.12 release candidate is installed for the final repeated device test. Android changes for this release are version metadata only (112); no phone installation is performed.


## Correction after owner-observed connection failures

- Do not treat the earlier eventual-return test as a clean handover. Unified logs show the legacy command associated with campus Wi-Fi without starting 802.1X; about 64 seconds later native auto-join started the EAP client, authenticated in about 0.4 seconds, and acquired IPv4 in about 0.2 seconds. The longer wait masked this backend defect.
- During the incomplete join, native hotspot clicks failed before authentication: kernel scan logs say `join manager is busy`, and ControlCenter reports ENETUNREACH. An earlier cached-hotspot failure family followed the local test watcher's explicit cleanup Off; those failures are not evidence of wrong credentials or Bluetooth interference.
- Replace `networksetup` with CoreWiFi association using the exact scanned result and existing known profile; retain complete EAP configuration, leave credentials inside macOS and suppress credential prompts. Runtime availability and exact SSID/profile checks fail closed. The project already uses CoreWiFi for its channel scanner.
- A logical timeout retains the native operation until its natural reply and rejects competing joins. Before sleep, cancel the owned request and suppress callbacks; only a fresh full-wake lifecycle resets a cancelled in-flight lease. An OS cancellation acknowledgement is not proof that radio association has physically stopped.
- Three profile tests, one default-EAP test, and two ownership tests bring the suite to 101 passing Mac tests. A local `connect-hotspot` diagnostic uses the same native backend only while preferred handover is held, and is blocked in sleep/DarkWake.
- Native-profile candidate installed at the single application path. Final hardware timing test is pending Mac unlock; release remains on hold. No Android runtime changes or phone installation.

## Actual device validation — 20 November 2026

- Stable project-signed trials A/B retain actual Bluetooth and Wi-Fi usability across changed installed builds; the owner confirmed no repeated authorization dialogs. Existing-campus verification turned the phone off only after the Wi-Fi-bound TLS probe.
- The actual saved-profile phone join failed before association. Airportd’s NSXPC decoder rejected scan-request SSID bytes because CWFScanParameters requires NSString. Runtime properties independently confirm the parameter uses NSString while scan results/saved profiles use NSData.
- Correct only the scan-request representation; keep exact raw-byte matching for results/profiles. A real framework secure-coding regression failed first (102 tests, one failure), then passed with the correct string. A focused independent review confirmed the boundary and fix.
- Rebuild/sign the fixed runtime using the retained certificate and repeat the actual phone-to-campus handover before releasing. Previous failure restored the phone Off and left the Mac on its original campus network.
