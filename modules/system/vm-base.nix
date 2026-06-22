{
  config,
  lib,
  pkgs,
  ...
}: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "25.11";
  nix.settings.experimental-features = ["nix-command" "flakes"];
}
