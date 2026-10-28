# Local menu-label alignment verification

**User gate:** Prepare and install a local trial, then stop for the user to inspect On/Off repeatedly. No push, merge, release or Homebrew publication before that explicit acceptance.

**Observed defect:** Release 0.1.8 reserves overall width but still moves all command-label anchors by 5 points. In actual 1000×544 screenshots of the native preview, On labels start at x=121 and Off labels at x=131. The previous automated test checked width only and could not establish label alignment.

**Cause and approach:** AppKit lays out its implicit default checkmark differently from the explicit off-state image. Supply both states through the same documented state-image API and image representation. Render the system checkmark symbol at the menu font size, with template tinting, using the same image bounds as the blank Off representation. Keep the native NSMenu, selection state, actions and keyboard handling; do not introduce padding offsets or replace the menu with a custom popover.

**Verification:** Keep the width-only regression accurately named. Use the real MenuBarController in the isolated preview and capture paired screenshots at the same anchor. Compare actual label positions using `macos/Tests/MenuLayoutImageCheck.swift`, excluding checkmark/pointer/shortcut pixels. A width-only pass is not visual acceptance. The preview makes no Bluetooth requests and stores no personal preferences.

- [x] Reproduce the old defect in real On/Off captures: checker fails with dx=10 pixels on all four labels.
- [x] Confirm new On→Off captures: checker passes with dx=0, dy=0 for Automatic Mode, duration submenu, Settings and Quit.
- [x] Confirm a cold Off→On transition: all four labels again have dx=0, dy=0. Menu actions remain covered by the native tests. Physical keyboard/highlight inspection remains part of manual acceptance; the computer-use keyboard attempt dismissed the popup and is not recorded as a pass.
- [x] Run the Mac suite (53 passing tests) and build/verify the local universal app. Independent review found no blocking issue and independently repeated the old/new image check.
- [x] Back up the published app/preferences and install the local trial. Strict signature verification passes; binary SHA-256 is `7772b3cea14e48aeedb6e62d15bd71f585becfcc7995552b10e3059310520d18`. The registered helper (PID 44657, parent 1) remains running after Settings closes. All critical preferences were verified unchanged. Bluetooth is on; the phone is currently disconnected, which does not prevent testing Automatic Mode's menu layout. No phone commands were issued.
- [x] User visually accepted the installed trial and explicitly authorized push, merge, release and Homebrew update after the fully default Apple checkmark comparison.

Screenshots and local deployment receipts stay under ignored `build/`. Release metadata remains 0.1.8 until acceptance; trial bundle version is 0.1.9-local.1.

The final captures show all four text anchors at x=123 in both states, including cold Off→On. The old captures were x=121 vs x=131. The test-only image checker failed on the old pair and passed on both new pairs. Local deployment receipt: `build/local-trials/menu-alignment/verification.json`.


## Follow-up: fully default Apple state images

On 2026-10-28 the user requested a direct trial of the completely default NSMenuItem checkmark. Removed the entire onStateImage/offStateImage override, leaving only the existing .on/.off state assignment. Ran the real isolated native preview; no installed-app replacement, Bluetooth commands, or personal preference changes were needed.

Actual light-appearance 1000x544 captures are stored in ignored build/menu-default-on.jpg and build/menu-default-off.jpg. A disposable copy of the pixel checker used dark-text detection (RGB below 100/255); the Automatic Mode On region began at x=110 to exclude the checkmark, while its Off region began at x=88. Other label regions were identical in both images. All four labels moved by dx=-28, dy=0 pixels, equivalent to 14 points at the captured 2x scale. The default-state preview exited normally after the comparison.

Restored the explicit matched state-image source byte-for-byte from its local backup. The Mac suite again passed all 53 tests. The previously installed 0.1.9-local.1 remains unchanged. No push, merge, release, or Homebrew update was performed. This comparison now establishes that the entirely default checkmark also shifts this menu's label column on the current Mac; it does not claim all macOS versions behave identically.


## Publication authorization

The user approved retaining the matched state-image implementation and explicitly requested push, merge, release and update. Prepare release 0.1.9 (Android versionCode 109, metadata-only Android change) through the existing single GitHub Actions publisher and shared Homebrew tap.
