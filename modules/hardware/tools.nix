{
  config,
  lib,
  pkgs,
  ...
}: let
  mountPoint = "/tools";
  subvol = "@tools";

  # /tools is a dedicated subvolume of the SAME btrfs filesystem that holds
  # the root subvolume. Both hosts use one btrfs device with @-prefixed
  # subvolumes (@nixos_root, @nix, @home, @log, @swap), so taking the device
  # from "/" keeps the UUID in one place and this module host-agnostic.
  rootDevice = config.fileSystems."/".device;

  # Mirror the root subvolume's mount options (compress=zstd on asusg16,
  # nothing extra on macbook) with the subvolume selector swapped, so /tools
  # follows each host's existing convention instead of hardcoding one.
  baseOptions = lib.filter (o: !(lib.hasPrefix "subvol=" o)) config.fileSystems."/".options;

  mountUnit = "${builtins.replaceStrings ["/"] [""] mountPoint}.mount";

  # Owner of the subvolume: the local.nix user and its primary group (both
  # hosts define that user through modules/users/main-user.nix).
  user = config.local.username;
  group = config.users.users.${user}.group;
in {
  fileSystems.${mountPoint} = {
    device = rootDevice;
    fsType = "btrfs";
    # noatime: read-mostly tree (same reasoning as the @nix subvolume).
    # nofail: insurance only — /tools is not needed to boot, and the create
    # unit below makes the subvolume exist in practice; without nofail a
    # missing subvolume would wedge boot instead of degrading.
    options = baseOptions ++ ["subvol=${subvol}" "noatime" "nofail"];
  };

  # Mounting does NOT create a btrfs subvolume: if @tools is absent the mount
  # fails. Create it once, ordered before the first mount. The root
  # subvolume of the same device is already mounted at this point, so the
  # device exists; the top-level (subvolid=5) is mounted temporarily because
  # a subvolume can only be created as a sibling from the top level.
  systemd.services.create-tools-subvolume = {
    description = "Create the ${subvol} btrfs subvolume for ${mountPoint}";
    # DefaultDependencies would order this after basic.target, i.e. after the
    # local-fs mounts it must precede — hence the opt-out.
    unitConfig.DefaultDependencies = false;
    before = [mountUnit];
    requiredBy = [mountUnit];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      top=$(mktemp -d /run/btrfs-toplevel.XXXXXX)
      trap '${pkgs.util-linux}/bin/umount "$top" 2>/dev/null || true; rmdir "$top" 2>/dev/null || true' EXIT

      ${pkgs.util-linux}/bin/mount -o subvolid=5 ${rootDevice} "$top"
      if [ ! -e "$top/${subvol}" ]; then
        echo "creating btrfs subvolume ${subvol} on ${rootDevice}"
        ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$top/${subvol}"
      else
        echo "btrfs subvolume ${subvol} already exists"
      fi

      # Hand the subvolume root to the main user. This is done here, not just
      # via systemd.tmpfiles, because tmpfiles-setup runs once at boot and can
      # precede the FIRST mount of this subvolume (nixos-rebuild switch mounts
      # it later, without restarting tmpfiles): the rule would then be applied
      # to the hidden directory under the root subvolume and the visible
      # subvolume root would stay root-owned. chown through the top-level
      # mount reaches the same inode. Mode is set explicitly too, since the
      # umask at creation time is not guaranteed (a tight umask yields 0700).
      ${pkgs.coreutils}/bin/chown ${user}:${group} "$top/${subvol}"
      ${pkgs.coreutils}/bin/chmod 0755 "$top/${subvol}"
    '';
  };

  # Fallback for the case where the mount fails (nofail): /tools then exists
  # as a plain directory on the root subvolume, and this keeps it usable and
  # correctly owned. The authoritative ownership fix is the chown in the
  # create unit above, which does not depend on mount/tmpfiles ordering.
  systemd.tmpfiles.rules = [
    "d ${mountPoint} 0755 ${user} ${group} -"
  ];
}
