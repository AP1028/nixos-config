{
  inputs,
  lib,
  ...
}: let
  comfyuiNixSrc = inputs.comfyui-nix.outPath;

  # The vendored wheel builds (comfyui-manager, comfy-kitchen, ...) declare
  # Requires-Dist deps that only exist at runtime in the final python env, so
  # nixpkgs' pythonRuntimeDepsCheck fails the build. Skip the check, matching
  # the project's own pattern (dontCheckRuntimeDeps).
  comfyuiNix = import "${inputs.nixpkgs}";

  # Fresh nixpkgs instance (not the system pkgs): avoids infinite recursion
  # with the comfy-ui-cuda overlay defined below, and matches how the
  # upstream flake builds its packages.
  pkgs = comfyuiNix {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };

  comfyuiSrc = pkgs.applyPatches {
    name = "comfyui-nix";
    src = comfyuiNixSrc;
    patches = [../../packages/patches/comfyui-nix-deps-check.patch];
  };

  versions = import "${comfyuiSrc}/nix/versions.nix";

  pythonOverrides = import "${comfyuiSrc}/nix/python-overrides.nix" {
    inherit pkgs versions;
    gpuSupport = "cuda";
  };

  comfyuiCuda = import "${comfyuiSrc}/nix/packages.nix" {
    inherit pkgs lib versions pythonOverrides;
    gpuSupport = "cuda";
  };
in {
  imports = [
    "${comfyuiSrc}/nix/modules/comfyui.nix"
  ];

  nixpkgs.overlays = [
    (final: prev: {
      comfy-ui-cuda = comfyuiCuda.default;
      comfy-ui = comfyuiCuda.default;
    })
  ];

  # comfyui-nix suggests these binary caches (its own builds).
  nix.settings.extra-substituters = [
    "https://comfyui.cachix.org"
    "https://nix-community.cachix.org"
    "https://cuda-maintainers.cachix.org"
  ];
  nix.settings.extra-trusted-public-keys = [
    "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
  ];

  services.comfyui = {
    enable = true;
    # NVIDIA CUDA support via pre-built PyTorch CUDA wheels (Pascal..Blackwell).
    gpuSupport = "cuda";
    listenAddress = "0.0.0.0";
    port = 8188;
    # Models live under /var/lib/comfyui/models/{diffusion_models,text_encoders,vae}
    dataDir = "/var/lib/comfyui";
    openFirewall = true;
  };
}
