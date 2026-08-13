{
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    screen
  ];
}
