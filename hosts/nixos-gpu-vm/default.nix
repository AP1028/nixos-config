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
    ../../modules/system/sudo-env-headless.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-gpu-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/services/vscode-server.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix

    ./gpu.nix

    ./packages
  ];
}
