{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./hardware
    ./networking
    ./packages
    ./system

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix {host = "macbook";})

    ../../modules/users/main-user.nix

    ../../modules/desktop
    ../../modules/system/i18n.nix

    ../../modules/services/audio.nix
    ../../modules/services/clash-verge.nix
    (import ../../modules/services/iptables-clash-openwrt.nix {interface = "wlan0";})

    ../../modules/env/sudo-env.nix
  ];
}
