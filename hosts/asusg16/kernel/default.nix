{
  config,
  lib,
  pkgs,
  ...
}: {
  # Latest kernel for newer hardware support (WiFi 7, Intel NPU, etc.).
  # Pinned to the 7.1 series: the out-of-tree i915-sriov patchset (strongtz,
  # kernel-v7.1 branch) has no 7.2 support yet — building it against 7.2 fails
  # on drm API changes (intel_display_types.h incomplete-type errors). Bump
  # once i915-sriov-dkms gains a kernel-v7.2 branch.
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  boot.kernelModules = [
    "kvm-intel" # nested VM acceleration
    # "88x2bu" # Realtek USB Wi-Fi driver
  ];

  # Out-of-tree Realtek 88x2bu Wi-Fi module
  # boot.extraModulePackages = with config.boot.kernelPackages; [rtl88x2bu];

  # Crash/hang forensics. kdump reserves 128M and kexec-loads a crash kernel at
  # boot (no steady-state cost); it also sets nmi_watchdog=panic and
  # softlockup_panic=1, so hard/soft lockups become panics we can capture.
  # After a crash the crash kernel drops to a rescue shell; save the dump with:
  #   mount -o subvol=/ /dev/nvme1n1p2 /mnt
  #   mkdir -p /mnt/var/crash && cp /proc/vmcore /mnt/var/crash/vmcore-$(date +%s)
  boot.crashDump.enable = true;

  boot.kernel.sysctl = {
    "vm.max_map_count" = 1048576; # Multiplies the default limit to allow deep memory maps
    "kernel.panic" = 10; # Reboot 10s after a panic instead of sitting dead
    "kernel.panic_on_oops" = 1; # Oops -> panic, so kdump captures it
    "kernel.sysrq" = 1; # Enable Alt+SysRq+w/l/t and /proc/sysrq-trigger
    # "kernel.hung_task_panic" = 1; # Optional: D-state >120s -> panic (can false-positive on VM I/O)
  };

  # Hardware watchdog (iTCO): auto-reboot if the kernel truly hard-locks.
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
}
