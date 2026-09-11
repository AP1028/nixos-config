{
  config,
  lib,
  pkgs,
  ...
}: let
  # Upstream Blackmagic re-released the 21.1 Linux archives without bumping the
  # version, so nixpkgs' fixed-output hashes no longer match (both variants).
  # Same fix as nixpkgs PR #562336. The package is an FHS env whose scripts
  # bake in the inner derivation's store path, so the hash cannot be fixed via
  # overrideAttrs; patch the package source at eval time instead. Once the PR
  # is in our nixpkgs the replacement finds nothing, the overlay becomes a
  # no-op, and this block can be dropped.
  davinci-hash-fixes = {
    "sha256-bQ4Yag4xfIF9Fs0UVKaYFhObMsAof5n+Sy4osw35a9g=" = "sha256-+3SB32EHpH9/0hM3h8CrO6f7V4ZAmxUFh3P8m6QDeO0=";
    "sha256-D5RjUukwKMpULrDfMJOPsPWW9FxhQ/IUMh76u5JLytA=" = "sha256-P+zu8/OuFcDcIkwV3UMq0qg9U2JEGRkKDP+VLQesZjw=";
  };
  davinciSrc = builtins.readFile (pkgs.path + "/pkgs/by-name/da/davinci-resolve/package.nix");
  davinciSrcFixed = builtins.replaceStrings (builtins.attrNames davinci-hash-fixes) (builtins.attrValues davinci-hash-fixes) davinciSrc;

  # DaVinci Resolve needs the NVIDIA dGPU — wrap it with the offload environment
  # variables so it always runs on the discrete GPU.
  davinci-resolve-wrapped = pkgs.symlinkJoin {
    name = "davinci-resolve-wrapped";
    paths = [pkgs.davinci-resolve];
    buildInputs = [pkgs.makeWrapper];

    postBuild = ''
      wrapProgram $out/bin/davinci-resolve \
        --set __NV_PRIME_RENDER_OFFLOAD 1 \
        --set __GLX_VENDOR_LIBRARY_NAME nvidia \
        --set CUDA_VISIBLE_DEVICES 0 \
        --set OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors/nvidia.icd
    '';
  };
in {
  nixpkgs.overlays = [
    (final: prev: {
      davinci-resolve =
        if davinciSrcFixed == davinciSrc
        then prev.davinci-resolve
        else prev.callPackage (builtins.toFile "davinci-resolve-fixed.nix" davinciSrcFixed) {};
    })
  ];

  environment.systemPackages = with pkgs; [
    davinci-resolve-wrapped
  ];
}
