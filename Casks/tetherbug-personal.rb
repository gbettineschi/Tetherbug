cask "tetherbug-personal" do
  version "0.1.6"
  sha256 "c261a9c04920a1e26064a1e984fd8d5595e5967b8d2028263816cbc5be9f2562"

  url "https://github.com/gbettineschi/Tetherbug/releases/download/v#{version}/Tetherbug-v#{version}.zip"
  name "Tetherbug Personal"
  desc "Android hotspot control from a native Mac menu"
  homepage "https://github.com/gbettineschi/Tetherbug"

  depends_on macos: :sonoma

  app "Tetherbug.app"
  binary "#{appdir}/Tetherbug.app/Contents/MacOS/Tetherbug", target: "tetherbug"

  uninstall quit: "ie.xav.tetherbug",
            launchctl: "ie.xav.tetherbug.agent"

  caveats <<~EOS
    This personal build is ad-hoc signed and not notarized. macOS may require
    approval in System Settings → Privacy & Security and renewed Bluetooth access.
    Quit any existing Tetherbug copy before moving to this Homebrew installation.
  EOS
end
