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
    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-file-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/users/service.nix

    ../../modules/services/vscode-server.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix

    ./services/samba.nix

    ./packages
  ];

  # ZFS for the HDD pool: declaring the ZFS mountpoint enables ZFS support
  # (boot.supportedFilesystems.zfs -> boot.zfs.enabled) and the auto-import of
  # the exported "HDD" mirror at boot; it mounts at /HDD and Samba shares it.
  networking.hostId = "3c91a2f4"; # required by ZFS; stable per host
  fileSystems."/HDD" = {
    device = "HDD";
    fsType = "zfs";
  };
}
