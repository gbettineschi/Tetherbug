# Stable Mac signing

The owner requested the same free permission-preserving signing approach already tested for Keepresso Mobile. Tetherbug currently has an ad-hoc cdhash identity which changes per build.

Use a separate persistent Tetherbug project certificate, the unchanged identifier ie.xav.tetherbug, and the default exact certificate-leaf designated requirement. Do not share Keepresso keys, add certificate trust, reset TCC, notarize, change Android or install extra app copies. Existing permissions can require one migration approval.

Prefer the tested self-signed project-certificate approach to continued ad-hoc signing; paid Developer ID remains unnecessary for this purpose. Self-signing does not bypass Gatekeeper.

Build and test without the Mac private key. A separate fresh signing runner, protected by owner-only review, validates a bounded single-app archive, signs without executing it, and publishes only the signed ZIP plus receipt. Releases fail closed without this identity. Support an unpublished exact-commit Mac-only trial. Provisioning a three-year project-only key and storing it in GitHub secrets is a separate explicit owner activation step after scripts/tests/review are ready.

Acceptance: two changed builds signed with the same certificate have identical DRs; the second real in-place update retains usable Bluetooth and Location grants. Keep the Wi-Fi handover release on hold until both permission retention and the Bocconi handover are verified.
