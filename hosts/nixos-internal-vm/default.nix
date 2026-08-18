{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./networking

    ../../modules/system/vm-base.nix
    (import ../../modules/system/i18n.nix {})
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-internal-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/users/service.nix

    ../../modules/services/vscode-server.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix

    ./services/sillytavern.nix
    ./services/dsh.nix
    ./services/nginx.nix

    ./packages
  ];
}
