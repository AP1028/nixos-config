{pkgs, ...}: {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  nixpkgs.config.permittedInsecurePackages = [
    "graalvm-oracle_17"
    "graalvm-oracle_22"
  ];

  system.stateVersion = "25.11";

  systemd.settings.Manager.RebootWatchdogSec = "2m";
  systemd.services.debug-shell.enable = true;

  # Steam runtime scripts use #!/bin/bash which doesn't exist on NixOS
  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
  ];
}
