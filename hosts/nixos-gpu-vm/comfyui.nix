{
  inputs,
  lib,
  ...
}: let
  # Uses upstream comfyui-nix unmodified: comfyui-nix pins its own nixpkgs
  # (f13ff45a) whose closures their CI builds and tests on main, so the env
  # is built from versions known to pass. No local patches/overrides.
  comfyuiSrc = inputs.comfyui-nix.outPath;

  # comfyui-nix's OWN pinned nixpkgs (their CI builds/tests against it).
  comfyuiNix = inputs.comfyui-nix.inputs.nixpkgs.outPath;

  # Fresh nixpkgs instance (not the system pkgs): avoids infinite recursion
  # with the comfy-ui-cuda overlay defined below, and matches how the
  # upstream flake builds its packages. Uses comfyui-nix's OWN pinned nixpkgs
  # so store paths hit their comfyui.cachix.org binary cache.
  pkgs = import comfyuiNix {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };

  versions = import "${comfyuiSrc}/nix/versions.nix";

  basePythonOverrides = import "${comfyuiSrc}/nix/python-overrides.nix" {
    inherit pkgs versions;
    gpuSupport = "cuda";
  };

  pythonOverrides = basePythonOverrides;

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
