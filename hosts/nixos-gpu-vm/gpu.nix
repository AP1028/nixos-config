{
  config,
  lib,
  pkgs,
  ...
}: {
  services.xserver.videoDrivers = ["nvidia"];

  hardware.graphics.enable = true;

  # Driver unpinned: previously pinned to legacy_580 for the old Pascal cards
  # (GTX 1060 / Tesla P40). Now on 2x RTX 2080 Ti (Turing), so the default
  # stable driver (595.x) is used.
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    open = false;
  };

  environment.systemPackages = with pkgs; [
    cudaPackages_12_9.cudatoolkit
    nvtopPackages.nvidia
  ];
}
