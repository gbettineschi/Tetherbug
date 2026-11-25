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

## Task 3: Timed hotspot preference and shared switching cooldown

Files: macos/Sources/WifiPreferenceControl.swift, macos/Sources/WifiHandover.swift, macos/Sources/MenuBar.swift, macos/Sources/Agent.swift, macos/Sources/Protocol.swift, macos/Tests/WifiPreferenceTests.swift, macos/Tests/MenuBarTests.swift, macos/test.sh.

- [ ] Add failing policy tests: six-hour persisted deadline, replacement, menu cancellation/expiry only, external-change five-minute cooldown in both directions, no delay for owned changes, no-quality fallback outside the preference, two failed probes, stale callbacks and sleep.
- [ ] Implement one shared handover state machine for both directions plus a bounded hotspot-preference internet-check policy; arbitrate one service owner. Add native duration submenu, six-hour choice and stop action; preserve stable checkmark spacing.
- [ ] Run the complete native suite and universal build. Review all changes, preserve the retained signer, install one app in place and record real test limits.

## Execution notes

- Task 1 RED: blocking-call completion during sleep left ownership stuck under the old private adapter (108 tests, 1 failure).
- Task 1 extra RED: enterprise security variants/OWE routed incorrectly in the first public adapter (111 tests, 5 assertions); corrected explicit public security selection.
- Additional scope is user-requested. Temporary hotspot preference overrides disconnected-only activation solely while its timer and Automatic Mode are active. Expiry/menu only cancellation was explicitly chosen.

### Final independent review and fix pass

The independent reviewer identified important cases: saved security downgrade, interactive or empty enterprise credentials, unavailable probes counted as failures, unknown association counted as offline, stale attempt ownership, failed restoration stuck on a bad hotspot, switching with Shizuku unavailable, manual changes just before preference activation, and stale/competing cache scans. Added scoped regressions and corrected them in one fix pass. Confirmed SystemConfiguration’s public physical-link read on this Mac returns Active=true. Native suite after this pass: 129 tests, zero failures (before the final strengthened interaction assertion and cache guard).

Ruling: CoreWLAN’s legacy Wi-Fi Keychain helpers need the public legacy Security interaction switch to guarantee unattended lookups. Serialize and scope that process-local switch, restore it on exceptions, and fail closed on denied/interaction-required credentials; do not invent an enterprise profile or assume nil credentials are reused. SDK deprecation warnings are expected for this narrowly scoped switch.
Ruling: Six hours is also offered in the general Automatic Mode duration list, reusing the same native duration type; hotspot preference has no indefinite option because the request is temporary.
Ruling: Existing Location authorization allows observing association changes even when return-to-preferred is disabled, so a newly selected hotspot preference respects a just-made external network choice. No location updates are requested.

### Verification before the signed trial

- Independent review completed; all Important findings were addressed. No review items were declined as outside scope. The documentation minor was corrected.
- Added courtesy handling for an explicit physical disconnection, without repeatedly extending it during the disconnected interval. This prevents immediately retrying the Wi-Fi the user deliberately left; normal hotspot activation still uses its existing five-second delay.
- Added a regression that restoration waits for a timed-out association to actually return. Unknown or physically connected networks are never inferred offline from a missing SSID/IP path.
- Keyless release/environment tests: 13 passed; archive signer boundary tests: 15 passed; CI signer-wrapper tests: 5 passed.
- A signed Mac-only trial uses the existing protected identity and an exact-source branch rule, removed after acceptance. No Android runtime changes, no new certificate and no ad-hoc installation.

### First signed live trial and exact EAP credential fallback

- Signed trial 0.1.13-wifi.1 launched with the retained certificate, login item and phone pairing. Its public association attempt failed before joining with credentialsUnavailable; the previous private CoreWiFi entitlement error is gone. This is not yet a successful campus handover.
- Read-only saved-profile and Keychain metadata checks found the exact WPA2 Enterprise profile and an 802.1X Password item using Apple's EAPOL service convention. No password values were displayed or copied into logs/preferences.
- Added an exact-service, exact-802.1X-kind public Security lookup only for enterprise credentials when CoreWLAN's helper returns no usable credentials. Denied/interaction-required results still fail closed. Personal Wi-Fi retains CoreWLAN's public Wi-Fi password helper; no guessed generic-password schema is used.
- Explicit Settings access is limited to saved enterprise profiles. It permits the native Keychain prompt only after a user action and verifies a second noninteractive read before reporting background readiness. Real worker access and association still require the next signed live test.
- Independent credential-only review identified the enterprise kind restriction and one-time access feedback; both were addressed. The proposed personal fallback was removed altogether rather than retaining an unverified schema.

### Enterprise connection investigation after the failed trial

The explicit credential-access action failed with errSecAuthFailed. This is a Keychain authorization/authentication failure, not proof that the saved network password is wrong. The failed trial build performed this read before submitting its public enterprise association request; it has therefore not established that macOS itself cannot use the saved authentication profile.

A manual diagnostic using Apple's networksetup (no password supplied) returned exit0 but did not establish the authenticated enterprise connection and interrupted the user's existing connection. The user stopped further live switching. Automatic return is disabled locally pending a properly assessed approach. A subsequent Wi-Fi-bound HTTPS check succeeded; native eapolclient logs also showed successful EAP-PEAP authentication. Do not repeat this generic networksetup experiment on enterprise Wi-Fi or infer association from its exit status.

Read-only examination of the installed SDK, framework method metadata and function bodies established:
- The public enterprise CoreWLAN method forwards nullable credentials to a native user-mode 802.1X association request. Our credential prefetch/guard is an app policy, not a prerequisite established by the public API's declaration.
- Apple's open-source supplicant has an explicit fallback to its own saved credential item when no username/password is supplied and a client item/profile is available (eapolclient.tproj/Supplicant.c, near lines3520–3565). The remaining question is whether the public association path supplies the right saved profile/item for the user's networks; this is not yet a verified end-to-end fix.
- A tempting private method named associateTo8021XNetwork:error: actually forwards to the login-window-mode association path on this OS. Do not choose it by name or invoke it for the logged-in user flow.
- The system Wi-Fi UI has Apple-specific Wi-Fi authentication/join privileges. Running a generic command with sudo is not evidence that it gains the UI's full saved-profile behavior.

No product code was changed during this read-only investigation, no root test was performed, and no further connection method was invoked after the user's stop. Before any later live test, determine the exact user-mode profile path, prepare bounded recovery and agree the test window. The draft PR must not be merged/released as a working campus handover.

Primary references: Apple's CoreWLAN CWInterface.h and enterprise association documentation; https://github.com/apple-oss-distributions/eap8021x/blob/main/eapolclient.tproj/Supplicant.c ; Apple's Security Framework Result Codes.

### User-selected simplification: delegate enterprise authentication

The user explicitly selected the public native API, with saved credentials handled by macOS. Removed enterprise credential prefetch, the custom Keychain helper and the credential-authorization menu. The existing exact saved SSID/security selection now directly calls the public enterprise association method with nil identity, username and password. Personal Wi-Fi keeps its existing scoped public password helper. No private association method or sudo is added.

This removes the app-side gate that prevented submitting the native8021X request. It does not prove the OS will reuse the correct saved enterprise profile. Existing state/settlement/internet verification remains mandatory. Current local build is unchanged and automatic return remains disabled; no real Wi-Fi connection was changed during this implementation. Removed three obsolete helper-specific tests; the remaining131 native tests passed.

The focused review found no Important/Critical regression in the simplification. macOS may still display its own authentication or certificate-trust dialog. An app timeout cannot dismiss that UI or forcibly cancel an association already submitted to the OS; Tetherbug never approves it on the user’s behalf. Prompt behavior and campus handover remain unverified.

### Authorized real-network test,25November

The user explicitly authorized the hotspot-to-saved-campus-network test. Enabled Return to preferred Wi-Fi through the app’s native Settings. The installed same-signer0.1.13-wifi.3 worker found the target but failed with NSPOSIXErrorDomain code16(EBUSY). Disabled automatic return through Settings after this one failed attempt. The phone hotspot stayed on; a Wi-Fi-bound HTTPS check after the failure succeeded. No further association experiment, root command, credential access or profile/trust modification followed.

The current catch logs only error domain/code. It covers both the extra directed scan and the actual association, so this result does not establish which stage returned busy and does not establish whether saved8021X authentication was exercised. The handover service first scans all networks and the adapter subsequently performs another directed scan; a scan collision is a hypothesis, not a verified cause. QuickDrop was running, but no evidence currently attributes the busy error to it. Do not remove security/sleep guards or add retries based on that assumption. Capture the precise failing stage before another live test. The draft is not ready to merge/release as a functioning saved-network handover.
