{...}: {
  system.copySystemConfiguration = true;

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  nixpkgs.config.permittedInsecurePackages = [
    "graalvm-oracle_17"
    "graalvm-oracle_22"
  ];

  system.stateVersion = "25.11";

  systemd.settings.Manager.RebootWatchdogSec = "2m";
  systemd.services.debug-shell.enable = true;
}
