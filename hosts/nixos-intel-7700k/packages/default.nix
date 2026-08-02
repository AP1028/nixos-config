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

  # ROCm 5.7.1 (last ROCm supporting gfx803 / RX 560) comes from the pinned
  # nixos-23-11 input; current nixpkgs has ROCm 7.x which dropped it.
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
      ripgrep
      rsync
      tree
      vim
      (oldPkgs.callPackage ../../../packages/llama-cpp-rpc.nix {
        rocmPackages = import ../../../packages/rocm-570.nix { inherit oldPkgs; };
      })
      oldPkgs.rocmPackages.rocminfo
    ];
}
