{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  programs.screen.enable = true;

  imports = [
    ./hardware-configuration.nix
    ./networking
    ./packages

    ../../modules/system/vm-base.nix
    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-essential-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix

    ./services/openvpn.nix
    ./services/wireguard.nix
    ./services/noip-duc.nix
    ./services/fastapi-dls.nix
  ];
}
