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

  # The vendored comfyui-manager wheel declares Requires-Dist deps that only
  # exist at runtime in the final python env, so nixpkgs'
  # pythonRuntimeDepsCheck fails its build on ANY nixpkgs (upstream CI
  # doesn't build this drv). Skip the check, matching the project's own
  # pattern (dontCheckRuntimeDeps).
  comfyuiPatched = pkgs.applyPatches {
    name = "comfyui-nix";
    src = comfyuiSrc;
    patches = [../../packages/patches/comfyui-nix-deps-check.patch];
  };

  # Fresh nixpkgs instance (not the system pkgs): avoids infinite recursion
  # with the comfy-ui-cuda overlay defined below, and matches how the
  # upstream flake builds its packages. Uses comfyui-nix's OWN pinned nixpkgs
  # so store paths hit their comfyui.cachix.org binary cache.
  pkgs = import comfyuiNix {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };

  versions = import "${comfyuiPatched}/nix/versions.nix";

  basePythonOverrides = import "${comfyuiPatched}/nix/python-overrides.nix" {
    inherit pkgs versions;
    gpuSupport = "cuda";
  };

  # mss (screen capture, KJNodes dep) has a test that needs an X display
  # (test_missing_fast_function_for_monitor_details_retrieval) which the nix
  # build sandbox never provides -> disable its tests. Everything else is
  # upstream-unmodified on their CI-tested nixpkgs.
  pythonOverrides = final: prev: (basePythonOverrides final prev) // {
    mss = prev.mss.overridePythonAttrs (old: {doCheck = false;});
  };

  comfyuiCuda = import "${comfyuiPatched}/nix/packages.nix" {
    inherit pkgs lib versions pythonOverrides;
    gpuSupport = "cuda";
  };
in {
  imports = [
    "${comfyuiPatched}/nix/modules/comfyui.nix"
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
