# Shared ComfyUI service setup, used by both nixos-gpu-vm (2x 2080 Ti) and
# asusg16 (RTX 5080 Mobile, Blackwell). Hosts pass enable/dataDir/listen/etc.
{
  inputs,
  lib,
  pkgs,
  enable ? true,
  dataDir ? "/var/lib/comfyui",
  listenAddress ? "0.0.0.0",
  port ? 8188,
  openFirewall ? true,
  customNodes ? {},
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

  # Flaky/infeasible test suites that fail regardless of nixpkgs rev:
  # - einops: checkInputs pull the whole Jupyter stack; jupyter-server's
  #   suite flakes (FD-leak + TimeoutError tests). Stack is only for docs.
  # - mss: test needs an X display, absent in the nix build sandbox.
  # - scipy: hypothesis property test flakes (1 failed / 87695 passed).
  # - triton/onnxruntime: same huge-suite risk class; runtime deps only.
  # - inline-snapshot: flaky doc-snapshot suite (3/1402); checkInput of
  #   fastapi, whose own suite then follows -> disable both.
  # - torch: the cu128 wheel's METADATA Requires-Dist lists nvidia-* and
  #   triton; upstream strips them in postInstall, but pythonRuntimeDepsCheck
  #   runs BEFORE install, so it always fails -> dontCheckRuntimeDeps.
  pythonOverrides = final: prev:
    let
      base = basePythonOverrides final prev;
    in
    base // {
      torch = base.torch.overridePythonAttrs (old: {
        dontCheckRuntimeDeps = true;
        # torch 2.10's METADATA also Requires-Dist cuda-bindings (a PyPI
        # wheel dep nix doesn't provide); upstream's sed only strips
        # nvidia-*/triton -> strip it here too.
        postInstall = (old.postInstall or "") + ''
          for metadata in "$out/${final.python.sitePackages}"/torch-*.dist-info/METADATA; do
            if [[ -f "$metadata" ]]; then
              sed -i '/^Requires-Dist: cuda-bindings/d' "$metadata"
            fi
          done
        '';
      });
      # facexlib wheel METADATA names deps opencv-python/tqdm; nix provides
      # opencv4 -> name mismatch -> same pre-install check failure.
      facexlib = base.facexlib.overridePythonAttrs (old: {dontCheckRuntimeDeps = true;});
      # xformers setup.py requires cuda-bindings==12.9.4 (a torch-2.10 wheel
      # dep nix strips); relax that requirement too.
      xformers = base.xformers.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or []) ++ ["cuda-bindings"];
      });
      einops = prev.einops.overridePythonAttrs (old: {doCheck = false;});
      mss = prev.mss.overridePythonAttrs (old: {doCheck = false;});
      scipy = prev.scipy.overridePythonAttrs (old: {doCheck = false;});
      triton = prev.triton.overridePythonAttrs (old: {
        doCheck = false;
        # NOTE: cannot scope triton to the nvidia backend — 3.7's core
        # (gluon_ir.cc) hard-includes the amd dialect's generated headers.
      });
      onnxruntime = prev.onnxruntime.overridePythonAttrs (old: {doCheck = false;});
      inline-snapshot = prev."inline-snapshot".overridePythonAttrs (old: {doCheck = false;});
      fastapi = prev.fastapi.overridePythonAttrs (old: {doCheck = false;});
    };

  comfyuiCuda = import "${comfyuiPatched}/nix/packages.nix" {
    inherit pkgs lib versions pythonOverrides;
    gpuSupport = "cuda";
  };
in {
  imports = [
    "${comfyuiPatched}/nix/modules/comfyui.nix"
  ];

  # Only install the overlay when the service is enabled: comfyuiCuda is a
  # lazily-evaluated pinned-nixpkgs import, so leaving it out keeps the
  # eval cheap on hosts that are not running ComfyUI yet.
  nixpkgs.overlays = lib.mkIf enable [
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
    enable = enable;
    # NVIDIA CUDA support via pre-built PyTorch CUDA wheels (Pascal..Blackwell).
    gpuSupport = "cuda";
    listenAddress = listenAddress;
    port = port;
    # Models live under ${dataDir}/models/{diffusion_models,text_encoders,vae}
    dataDir = dataDir;
    openFirewall = openFirewall;
    customNodes = customNodes;
  };
}
