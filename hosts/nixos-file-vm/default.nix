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
  # Never force-import a foreign root pool (data-safety; the HDD data pool is
  # imported normally by zfs-import-HDD.service).
  boot.zfs.forceImportRoot = false;
  fileSystems."/hdd" = {
    device = "HDD";
    fsType = "zfs";
    # A failed import must not drop the system to emergency: the zfs kernel
    # module is only loaded at the NEXT boot (kernelModules), so a live
    # "nixos-switch" activation imports before the module exists and fails.
    # nofail (fstab option) keeps the switch/boot going; the reboot mounts it.
    options = ["nofail"];
  };
}
