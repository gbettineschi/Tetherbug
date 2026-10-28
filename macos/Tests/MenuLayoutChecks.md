# Native menu visual check

The width assertion in `MenuBarTests.swift` does **not** prove that individual labels stay aligned. A menu can retain its width while AppKit moves its state-image column.

For changes to state images, also run `macos/test.sh preview`. This uses the real menu controller with a simulated phone, without Bluetooth or personal preferences. Open **Show hotspot menu**, capture the On state, click **Automatic Mode**, reopen at the same anchor and capture Off. Capture the complete same-size preview window in both cases. Test both transition directions, including opening the menu for the first time with Auto off. Inspect keyboard navigation and the highlighted/disabled checkmark as well.

Start with `TETHERBUG_PREVIEW_AUTOMATIC=off macos/test.sh preview` to check the first menu opening while Auto is off.

`MenuLayoutImageCheck.swift` compares the actual text anchors in dark-appearance screenshots. Supply regions containing only the bright label prefix: exclude the checkmark, mouse pointer, submenu arrow and shortcut glyphs. Region coordinates are screenshot pixels, not points. A zero exit code requires exactly identical horizontal and vertical anchors.

For a 1000×544 capture of the current 500-point preview window:

```sh
swift macos/Tests/MenuLayoutImageCheck.swift on.jpg off.jpg \
  'Automatic Mode=118,277,370,302' \
  'Duration submenu=118,323,380,350' \
  'Settings=118,394,330,421' \
  'Quit=118,442,400,469'
```

If the preview frame, appearance, scale or menu geometry changes, inspect new captures and choose appropriate text regions. Do not infer visual alignment from passing policy tests or menu width alone. A local visual check and the user's installed-app acceptance are required before publishing a layout fix.
