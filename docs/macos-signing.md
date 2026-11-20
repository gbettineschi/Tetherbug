# Stable Mac identity across updates

## Retained signing identity verified

Public releases through 0.1.11 were ad-hoc signed, changing privacy identity with each build. From 0.1.12, the project retains one certificate and bundle identifier. Two changed signed builds were installed in place on the owner’s Mac; live Bluetooth and Wi-Fi access remained usable, and the owner confirmed no repeated approval prompts. A reboot alone does not change a signature.

The owner requested the free project-certificate approach already tested for Keepresso Mobile. Tetherbug uses its own certificate and unchanged bundle identifier, `ie.xav.tetherbug`. The default designated requirement must be exactly that identifier AND the certificate leaf fingerprint. Never substitute an identifier-only or hash-based requirement. No paid Apple membership is needed; this does not provide Developer ID or notarization. Gatekeeper remains enforced.

Automated tests have signed two changed Tetherbug bundles with one temporary certificate and confirmed the identical default requirement. They rejected another signer, tampered resources and a wrong incoming code identifier, exercised the real archive signer and CI import/cleanup, and removed all temporary material. These automated tests do not grant privacy permissions. Separate real A/B installations established retained usable grants with the owner’s confirmation.

## Production activation

The owner approved activation on 20 November 2026. A dedicated three-year RSA-3072/SHA-256 code-signing certificate was generated in a private temporary directory; its encrypted identity was uploaded and temporary generation files removed. For any future deliberately approved replacement, generate it in a private temporary directory. Export password-encrypted PKCS12. Publish only its public certificate at `docs/signing/tetherbug-project.pem` and record its fingerprints. Do not reuse Keepresso keys, add trust or import the production identity into a personal keychain.

Store these three private values in the fork's **macos-release** GitHub environment: `MACOS_SIGNING_PKCS12_BASE64`, `MACOS_SIGNING_PKCS12_PASSWORD` (32+ random characters), `MACOS_SIGNING_CERTIFICATE_SHA1`. They must never appear in git, chat, logs or download artifacts. Before upload, verify owner-only required deployment review, disabled administrator bypass and selected refs restricted to `v*` tags plus the exact approved trial branch. The checked-in verifier repeats that check on the signing runner. After trial acceptance, remove the temporary branch rule.

The activated identity uses protected GitHub secrets as key custody; temporary generation files were deleted after successful provisioning. No independent encrypted backup destination has been selected or created. GitHub secret values cannot be downloaded again. Losing the retained key would require a deliberate signer change and renewed approvals; never silently generate a replacement. Certificate expiry/rotation also needs an explicit migration.

## Release path

A keyless job builds/tests the universal Mac ZIP. The retained-key Android builder is separate and unchanged in identity. A fresh Mac signing-only runner waits for owner approval, validates the bounded single-app archive, imports the configured certificate in a temporary keychain, signs without executing any candidate code and verifies its exact default requirement. A missing key or wrong identity fails without an ad-hoc fallback. Temporary keys/keychains are cleaned even on failure. Only the signed ZIP and public receipt leave this job.

The publisher accepts only that run's matching source/version/receipt and package hashes, checks the Mac signer against the committed public certificate, then creates the release and updates the tap. Installer artifacts expire after one day; public releases remain the usual long-lived update channel.

For an unpublished trial, dispatch **Release personal apps** from the exact approved branch with `mode: mac-trial`, `tag: v0.1.12-signing.1` and the reviewed full `expected_sha`. This signs only the Mac artifact, without Android credentials, publication or Homebrew changes. Use a second distinct trial version for update acceptance. Local development builds remain ad-hoc: do not install those over the stable signed production app if testing permission retention.

## Acceptance

Install candidate A at `/Applications/Tetherbug.app`, preserving all settings/pairing. The owner handles any initial Bluetooth/Location approval. Verify live usable grants. Update in place to changed candidate B signed by the same certificate; verify identical DR, usable Bluetooth/Location, preserved pairing and managed startup without repeated approval. A denied/revoked grant must remain denied. Keep a compressed rollback only, with one discoverable installed app. Do not reset TCC or weaken Gatekeeper to make a test pass.

Installed A/B acceptance and the real S23 hotspot-to-Bocconi handover have passed. No Android runtime or phone app update is part of this signing work.

References: [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).

## Activated public identity

- [Public certificate](signing/tetherbug-project.pem); [metadata](signing/tetherbug-project.json). These contain no private key.
- SHA-1: `4d467e05e0e1a7a35024e86f97cf6c30a28e95d8`.
- SHA-256: `9d1cf43945edd110ac5e5463699c116ff5313c8ea766f1dff16dfb12a00e6015`.
- Valid 20 November 2026 through 20 November 2029, 13:00:40 UTC.
- Protected environment and exact refs verified before upload; all three secret names verified afterward. Real installed-update permission retention passed.

## Hosted and local acceptance status — 20 November 2026

Both exact-source Mac-only trial workflows completed successfully using the retained certificate: [A](https://github.com/gbettineschi/Tetherbug/actions/runs/44744428908), [B](https://github.com/gbettineschi/Tetherbug/actions/runs/44744873344). The actual temporary-certificate integration also passed on the hosted runner. The fixture uses the native Mac exporter; Homebrew OpenSSL defaults produced an incompatible test PKCS12. Earlier macos-15 identity-lookup failures are recorded observations, not proof of an OS defect.

A and B were installed sequentially at the single canonical path. Both established live S23 Bluetooth and Wi-Fi identification/internet verification; the owner confirmed B did not request either permission again. Pairing and settings survived. No privacy database reset or certificate trust change was used.

The corrected native association backend was then tested from the actual S23 hotspot to Bocconi: enterprise EAP started immediately after association, DHCP completed, and stable internet was verified before switching the phone hotspot off. The campus join request to verified phone Off took about ten seconds. Initial phone-hotspot discovery required a retry; that delay is not included in the campus handover figure.

### Updated helper registration

macOS separately stores executable launch constraints for registered background services. Replacing a bundle while retaining an old launchd cdhash caused the owner’s CODESIGNING / Launch Constraint Violation reports. Certificate continuity for privacy permission does not remove this separate requirement.

The first completion-based repair, a 15-second delay, root-preserving replacement and per-app LaunchServices refresh all reproduced the first legacy-job rejection on the owner's Mac. Those are not accepted as fixes.

From 0.1.12, launch at login uses [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp), which launches the app at future logins. The app starts its ordinary independent session worker; it does not register or kickstart a fixed executable LaunchAgent after each update. An already-enabled legacy agent is unregistered asynchronously and migrated to native app login. Disabled or blocked legacy login stays disabled. Migration remains serialized and respects FullWake, approval and close/Quit ownership. No crash reporting or security protection is suppressed.

Changed signed-build startup acceptance is required before releasing this migration. A physical logout/reboot is not part of the automated update test and must not be claimed as observed.
