{
  config,
  lib,
  pkgs,
  ...
}: {
  system.copySystemConfiguration = true;
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  fonts.packages = with pkgs; [
    dejavu_fonts
    corefonts
  ];

  system.stateVersion = "25.11";
}
