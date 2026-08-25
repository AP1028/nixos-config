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

  boot.kernel.sysctl = {
    "vm.max_map_count" = 1048576; # Multiplies the default limit to allow deep memory maps
  };
}
