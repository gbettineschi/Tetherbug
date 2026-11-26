# Automatic Mode as the sole automation control

The user confirmed the new presence-only behavior and explicitly removed “Prefer hotspot for…”. This supersedes the override/timer portions of the 25 November presence design. Tetherbug detects preferred networks and controls phone On/Off; macOS continues to own all network selection and authentication.

- Remove the preference submenu, handlers, state field, settings message and policy veto.
- Purge the retired `preferHotspotUntil` key at startup without modifying Automatic Mode, its deliberate pause, the preferred list or the network-change courtesy deadline.
- Keep Automatic Mode, its timed suspension menu (including six hours), normal manual controls and the existing presence policy.
- Update permission-purpose copy to describe hotspot control and preferred-network detection accurately.

Verification: two regressions first failed (redundant menu still present; obsolete timer still retained), then the native suite passed 118 tests, 0 failures (`/tmp/tetherbug-remove-prefer-green.log`). Tests for the removed feature were replaced or retired; master-switch, BLE readiness, presence, sleep, native-menu geometry and login coverage remain.

- [x] Remove the override and update documentation.
- [x] Run regression tests and native suite.
- [x] Focused review found no Critical/Important issues; the universal build completed with 118 tests, 0 failures (`/tmp/tetherbug-presence2-candidate-build.log`).
- [x] Same-signer installation in place, preserving settings and one app.
- [x] Actual S23 On/Off verification with the Mac's Wi-Fi unchanged.


## Signed trial and device result

Installed `0.1.13-presence.2` from source `a74befa7e99750d38c1e9c640df0e2c9a0a550e5`. [Protected trial run 45867863777](https://github.com/gbettineschi/Tetherbug/actions/runs/45867863777) passed the 118 native tests, universal build, signing-boundary tests and retained-certificate signing. The temporary exact-branch signing rule was removed afterward; only version tags remain eligible for signing.

The app replaced `/Applications/Tetherbug.app` in place. Its designated requirement and both architectures were verified, a new worker connected to the controllable phone, native login remained enabled without pending approval or legacy registration, and the six preferred networks and master-switch settings were preserved. The retired timer is absent; the temporary previous bundle was deleted after verification. No Android change, release publication or Homebrew update was performed.

At 17:36 UTC on 26 November, the real-device trial switched Automatic Mode off, manually enabled the S23 hotspot, and observed it stay On for ten seconds. Re-enabling Automatic Mode produced `disable (preferred Wi-Fi available)` and a phone-confirmed Off at 17.53 seconds from trial start. The Mac's connection ID and gateway were identical before and after; interface-bound HTTPS returned 200. The original master mode, absence of a pause and preferred list were restored afterward. Evidence: `/tmp/tetherbug-single-mode-live-2026-11-26/result.json` and `states.jsonl`.

This proves preferred-presence-triggered hotspot shutdown and the global Mode Off veto. It does not claim a Wi-Fi association by Tetherbug: no association is attempted, and macOS remains responsible for joining another network.
