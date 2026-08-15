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
    ./services/nginx.nix
    ./services/uptime-kuma.nix

    ../../modules/system/vm-base.nix
    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix {host = "nixos-webapp-vm";})

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix
  ];
}
