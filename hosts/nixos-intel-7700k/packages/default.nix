{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ../../../modules/packages/common
    ../../../modules/packages/common/vm-common.nix
    ../../../modules/packages/opencode.nix
  ];

  # ROCm 5.7.1 (last ROCm supporting gfx803 / RX 560) stays available from the
  # pinned nixos-23-11 input (rocminfo etc.); llama.cpp itself is built with
  # Vulkan (RADV) instead, since modern llama.cpp requires ROCm >= 6.1 which
  # dropped gfx803. mesa provides the RADV ICD, vulkan-loader the runtime.
  environment.systemPackages =
    let
      oldPkgs = import inputs.nixos-23-11 {
        localSystem = pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      };
    in
    with pkgs; [
      bat
      btop
      curl
      eza
      fd
      jq
      kdePackages.kdialog
      amdgpu_top
      nvtopPackages.amd
      ripgrep
      rsync
      tree
      vim
      (pkgs.callPackage ../../../packages/llama-cpp-rpc.nix { })
      mesa
      vulkan-loader
      oldPkgs.rocmPackages.rocminfo
    ];
}
