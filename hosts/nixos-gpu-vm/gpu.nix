{
  config,
  lib,
  pkgs,
  ...
}: {
  # vGPU guest driver (grid 535.309.01) is provided by vgpu-guest.nix;
  # the nixpkgs desktop nvidia driver is disabled there (mkForce).
  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    cudaPackages_12_9.cudatoolkit
    nvtopPackages.nvidia
  ];
}
