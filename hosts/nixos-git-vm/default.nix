{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./networking

    ../../modules/system/vm-base.nix
    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-git-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/users/service.nix

    ../../modules/services/vscode-server.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix
    (import ../../modules/services/iptables-clash-openwrt.nix { interface = "ens18"; })

    ./services/gitea.nix

    ../../modules/desktop/plasma.nix
    ../../modules/env/xilinx-env.nix

    ./packages
  ];
}
