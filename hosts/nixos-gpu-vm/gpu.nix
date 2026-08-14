{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  # vGPU guest driver (grid 535.309.01) is provided by vgpu-guest.nix;
  # the nixpkgs desktop nvidia driver is disabled there (mkForce).
  hardware.graphics.enable = true;

  # CUDA toolkit must match driver 535 (max CUDA 12.2) -> nixos-23.11's
  # cudaPackages_12_2 (12.2 was removed from newer nixpkgs).
  environment.systemPackages = with pkgs; [
    (import inputs.nixos-23-11 {
      system = "x86_64-linux";
      config.allowUnfree = true;
    }).cudaPackages_12_2.cudatoolkit
    nvtopPackages.nvidia
  ];
}
