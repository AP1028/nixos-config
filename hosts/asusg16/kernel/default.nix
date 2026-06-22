{
  config,
  lib,
  pkgs,
  ...
}: {
  # Latest kernel for newer hardware support (WiFi 7, Intel NPU, etc.)
  boot.kernelPackages = pkgs.linuxPackages_latest;

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
