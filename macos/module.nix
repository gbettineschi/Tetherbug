# nix-darwin module: installs Tetherbug.app (and the `tetherbug` CLI) and runs its background agent
# as a launchd user agent, so the app's "Run in the background" login item isn't needed.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tetherbug;
in
{
  options.services.tetherbug = {
    enable = lib.mkEnableOption "Tetherbug, which turns your Android phone's hotspot on when the Mac loses Wi-Fi";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.tetherbug;
      defaultText = lib.literalExpression "tetherbug.packages.\${system}.tetherbug";
      description = "The Tetherbug package to install and run.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    launchd.user.agents.tetherbug.serviceConfig = {
      ProgramArguments = [
        "${cfg.package}/Applications/Tetherbug.app/Contents/MacOS/Tetherbug"
        "agent"
      ];
      RunAtLoad = true;
      # The agent exits cleanly when another copy already runs; restart it only if it crashes.
      KeepAlive.SuccessfulExit = false;
    };
  };
}
