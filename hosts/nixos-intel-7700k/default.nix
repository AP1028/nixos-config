{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  home-manager.users.${config.local.username}.local.home.fastfetch.enable = false;

  imports = [
    ./hardware-configuration.nix
    ./networking
    ./system
    ./packages
    ./desktop
    ./users

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-intel-7700k"; })

    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix

    ../../modules/hardware/common.nix

    ../../modules/services/audio.nix
    ../../modules/services/openssh.nix
    ../../modules/services/vscode-server.nix
  ];
}
