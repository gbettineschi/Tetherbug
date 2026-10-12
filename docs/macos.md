# Tetherbug for Mac

Tetherbug keeps a Bluetooth link to your Android phone and asks it to turn its hotspot on when your
Mac loses Wi-Fi. It has a window for status and settings, a background agent that does the work, and
a `tetherbug` command-line tool.

## 1. Set up the phone

Install the Tetherbug Android app from the
[releases page](https://github.com/xav-ie/Tetherbug/releases), then follow its setup checklist:
Bluetooth and notification permissions, [Shizuku](https://shizuku.rikka.app) (hotspot control needs
system rights), and start the service.

## 2. Pair the phone with your Mac

1. On your Mac, open **System Settings → Bluetooth** and leave it open so the Mac stays discoverable.
2. On the phone, open **Bluetooth settings → Pair new device** and pick your Mac.
3. Check that both screens show the same code and confirm on both within 30 seconds. If it times out,
   Android forgets the Mac; just pair again.

<p align="center"><picture><source media="(prefers-color-scheme: light)" srcset="../assets/images/pairing-light.svg"><img src="../assets/images/pairing.svg" alt="With Bluetooth settings open on the Mac, pick it under Pair new device on the phone and confirm the same code on both within 30 seconds; the bond carries the keys for Tetherbug's encrypted link."></picture></p>

Pairing also gives Tetherbug the keys for its encrypted Bluetooth LE link, so there's no second
prompt. Only a paired Mac can read the phone's status or turn its hotspot on.

## 3. Install Tetherbug

### With Nix (fastest)

Try it without installing anything:

```sh
nix run github:xav-ie/Tetherbug
```

To install it for good with [nix-darwin](https://github.com/nix-darwin/nix-darwin), add the flake and
enable its module. That puts **Tetherbug.app** in `/Applications/Nix Apps`, the `tetherbug` command
on your `PATH`, and runs the background agent at login through launchd:

```nix
# flake.nix
inputs.tetherbug.url = "github:xav-ie/Tetherbug";

# one of your darwinConfiguration's modules
{
  imports = [ inputs.tetherbug.darwinModules.default ];
  services.tetherbug.enable = true;
}
```

With the module you can leave **Run in the background** off: launchd already keeps the agent
running. Open Tetherbug once from Applications so macOS asks for Bluetooth access.

### With Homebrew

```sh
brew install xav-ie/tap/tetherbug
```

That installs **Tetherbug.app** in Applications and the `tetherbug` command.

### From the releases page

Download `Tetherbug-v<version>.zip` from the
[releases page](https://github.com/xav-ie/Tetherbug/releases), unzip it, and move **Tetherbug.app** to
Applications.

Tetherbug isn't notarized by Apple yet, so the first time you open a Homebrew or downloaded copy,
macOS blocks it. Allow it under **System Settings → Privacy & Security → Open Anyway**. Nix installs
aren't affected.

### From source

See [Development](development.md) to build the app yourself.

## 4. Run Tetherbug

Open Tetherbug and turn on **Run in the background**. macOS may ask you to allow it under
**System Settings → General → Login Items**, and asks once for Bluetooth access. The window then shows
your phone, its hotspot state and battery.

### Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Turn on hotspot when Wi-Fi is disconnected | on | When Wi-Fi stays disconnected for the wait below, ask the phone to turn its hotspot on. |
| After disconnected for | 5 sec | How long to give macOS's own auto-join (which bursts on wake) before asking, in seconds (0–600). |
| Run in the background | off | Starts the agent at login and keeps it running when the window is closed. |

### Command line

```sh
tetherbug status          # phone, hotspot state, battery, signal (--json for scripts)
tetherbug enable          # ask the phone to turn its hotspot on
tetherbug disable         # ...or off
tetherbug watch           # one JSON line every time the state changes
tetherbug debug on        # notify for everything the agent does (off to stop)
```

Using SketchyBar? See [Tetherbug in SketchyBar](sketchybar.md).

## Build from source

Needs the Xcode command line tools.

```sh
git clone https://github.com/xav-ie/Tetherbug
Tetherbug/macos/build.sh ~/Applications
open ~/Applications/Tetherbug.app
```
