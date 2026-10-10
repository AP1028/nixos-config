# APFS tooling for reading macOS volumes from Linux.
#
# Needed on any machine that has to inspect a macOS installation while booted
# into Linux -- extracting boot.efi for firmware enrolment, pulling files off an
# install, or checking a volume after a bad boot. apfs-fuse mounts APFS
# read-only; it cannot write, so an installed macOS cannot be damaged by it.
#
# ---------------------------------------------------------------------------
# NOT YET IMPLEMENTED -- design note only. Documented 2026-10-09.
# ---------------------------------------------------------------------------
#
# GOAL: the APFS partition shows up in Dolphin's Places panel, read-only,
# browsable, without typing mount commands. Ideally like a USB stick does.
#
# WHY CLICK-TO-MOUNT CANNOT WORK FOR APFS:
#   Dolphin mounts removable/internal partitions through udisks2, which asks the
#   kernel. Linux mainline has no APFS driver, and udisks2/libblockdev ship no
#   APFS plugin, so there is nothing for udisks to call. No kernel module is
#   packaged in nixpkgs either (checked: apfs-linux-kernel-module and
#   linux-apfs-rw are both absent; the upstream out-of-tree module is
#   read-only, DKMS-based, handles neither snapshots nor encryption, and breaks
#   across kernel versions). FUSE is therefore the only practical route.
#
# WHY THE GOAL IS STILL ACHIEVABLE:
#   Dolphin automatically lists everything under /run/media/<user>/ in Places.
#   So mounting apfs-fuse there gives the same visual result as clicking a
#   partition, without Dolphin needing to know APFS exists.
#
# PROPOSED DESIGN:
#   udev rule      fires when the APFS partition appears (by PARTLABEL/fs type)
#   systemd unit   runs:
#                    apfs-fuse -o allow_other,uid=<user>,gid=<group> \
#                              <device> /run/media/<user>/APFS
#   result         "APFS" appears in Dolphin Places, read-only, browsable
#
#   umount on removal, lazily, so yanking the vfio binding does not wedge it.
#
# PREREQUISITES, AND THEIR CURRENT STATE:
#   apfs-fuse                  provided by this module                     [ok]
#   user_allow_other in        REQUIRED before -o allow_other works.
#     /etc/fuse.conf           Already set on asusg16. NixOS equivalent is
#                              boot.kernelModules + a fuse.conf override, or
#                              programs.fuse.userAllowOther = true.          [ok]
#   -o allow_other,uid,gid     Without these the mount is user_id=0,group_id=0
#                              and the desktop user gets EACCES on the
#                              mountpoint -- this is the usual failure.      [todo]
#
# INTERACTION WITH VFIO:
#   On asusg16 the Windows/macOS NVMe is bound to vfio-pci by an initrd service
#   (hosts/asusg16/hardware/nvme-vfio.nix, which writes driver_override). While
#   bound, the APFS partition does not exist in Linux at all, so the automount
#   simply never fires. It triggers when vfio is released -- which is exactly
#   when the volume is wanted. Pair with manual helpers:
#
#     apfs-mount     clear driver_override, unbind vfio, probe nvme, mount
#     apfs-umount    unmount, rebind vfio-pci, restore driver_override
#
#   NOTE: driver_override must be cleared before probing or the nvme driver
#   refuses to bind. Sequence:
#     echo "" > /sys/bus/pci/devices/0000:02:00.0/driver_override
#     echo 0000:02:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
#     echo 0000:02:00.0 > /sys/bus/pci/drivers/probe
#
#   NOTE: device enumeration is NOT stable across reboots -- the same physical
#   disk appeared as nvme1n1 in one boot and nvme0n1 in the next. Resolve the
#   device by partition UUID or PARTLABEL, never by nvmeXnY.
#
# GOTCHAS LEARNED THE HARD WAY (worth keeping):
#   - pkill -f apfs-fuse matches the killer's own command line and kills it.
#     Use pkill -x apfs-fuse (exact process name).
#   - apfs-fuse mounts only one volume per process and -v N returned identical
#     content for every id tried. On macOS 11+ the file OpenCore loads is on the
#     Preboot volume, and the sealed System volume exposes a root/ + private-dir/
#     layout whose CoreServices does not contain boot.efi. Getting boot.efi is
#     markedly easier from a macOS recovery terminal than through apfs-fuse.
#   - Running apfs-fuse in the foreground over SSH hangs the session; it needs
#     setsid with stdin from /dev/null, or a bounded timeout.
#
# KIO-FUSE: unrelated to this. kio-fuse exposes KIO slaves (sftp://, smb://,
# mtp://) as FUSE mounts so non-KDE apps can open them. It does nothing for
# APFS, which is not a KIO slave. Add it separately if the sftp/mtp case matters.
{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    apfs-fuse # read-only APFS mount (FUSE)
    apfsprogs # apfsck / mkfs.apfs -- integrity checking and inspection
  ];
}
