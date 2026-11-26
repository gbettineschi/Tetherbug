# Automatic Mode as the sole automation control

The user confirmed the new presence-only behavior and explicitly removed “Prefer hotspot for…”. This supersedes the override/timer portions of the 25 November presence design. Tetherbug detects preferred networks and controls phone On/Off; macOS continues to own all network selection and authentication.

- Remove the preference submenu, handlers, state field, settings message and policy veto.
- Purge the retired `preferHotspotUntil` key at startup without modifying Automatic Mode, its deliberate pause, the preferred list or the network-change courtesy deadline.
- Keep Automatic Mode, its timed suspension menu (including six hours), normal manual controls and the existing presence policy.
- Update permission-purpose copy to describe hotspot control and preferred-network detection accurately.

Verification: two regressions first failed (redundant menu still present; obsolete timer still retained), then the native suite passed 118 tests, 0 failures (`/tmp/tetherbug-remove-prefer-green.log`). Tests for the removed feature were replaced or retired; master-switch, BLE readiness, presence, sleep, native-menu geometry and login coverage remain.

- [x] Remove the override and update documentation.
- [x] Run regression tests and native suite.
- [ ] Focused review and universal build.
- [ ] Same-signer installation in place, preserving settings and one app.
- [ ] Actual phone On/Off verification with the Mac's Wi-Fi unchanged, if the operational phone remains reachable.
