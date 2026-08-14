{
  pkgs,
  config,
  inputs,
  ...
}: let
  # GPUs here are 2x RTX 2080 Ti (Turing, sm_75). The CUDA arch list still
  # carries the old sm_61 (Pascal) entries plus sm_75 for the 2080 Ti.
  # rpcSupport compiles in the RPC backend + rpc-server for future llama RPC
  # work, but no RPC services/clients are configured yet.
  #
  # CUDA must match the vGPU guest driver (535.309.01 = max CUDA 12.2):
  # newer toolkits fail at kernel load ("device kernel image is invalid").
  # nixpkgs removed 12.2 from current inputs; only nixos-23.11 carries it.
  # The WHOLE llama build comes from 23.11 so stdenv/cmake/hooks match
  # (mixing 23.11 cuda into 26.05's build broke nixInfoLog/concatTo hooks).
  cuda23 = import inputs.nixos-23-11 {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  cudaPackages = cuda23.cudaPackages_12_2;
in {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    ((cuda23.llama-cpp.override {
      cudaSupport = true;
      inherit cudaPackages;
    }).overrideAttrs (old: {
      # b10331: adds DeepSeek V4 DSpark speculative decoding (PR #25784),
      # which the MXFP4 cluster uses to batch-verify 5 tokens per pass.
      version = "10331";
      src = fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        tag = "b10331";
        hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
        leaveDotGit = true;
        postFetch = old.src.postFetch;
      };
      # stable split-graph uids so the RPC graph cache (GRAPH_RECOMPUTE) engages
      patches = (old.patches or [ ]) ++ [ ../../../packages/patches/rpc-graph-cache.patch ../../../packages/patches/rpc-dspark-draft-path.patch ../../../packages/patches/rpc-debug-tensor-name.patch ../../../packages/patches/rpc-dsv4-compressed-cpu.patch ../../../packages/patches/rpc-server-repack.patch ];
      # b10331 moved the rpc-server to tools/rpc (target ggml-rpc-server) and
      # only installs it with LLAMA_TOOLS_INSTALL=ON. 23.11's llama-cpp has no
      # rpcSupport arg -> GGML_RPC here; arch list capped at sm_90 (nvcc 12.2).
      cmakeFlags = old.cmakeFlags ++ [
        "-DLLAMA_TOOLS_INSTALL=ON"
        "-DGGML_RPC=ON"
        "-DCMAKE_CUDA_ARCHITECTURES=61;75;80;86;89;90"
      ];
      npmDeps = fetchNpmDeps {
        name = "llama-cpp-10331-npm-deps";
        src = fetchFromGitHub {
          owner = "ggml-org";
          repo = "llama.cpp";
          tag = "b10331";
          hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
          leaveDotGit = true;
          postFetch = old.src.postFetch;
        };
        patches = [ ../../../packages/patches/rpc-graph-cache.patch ];
        preBuild = ''
          pushd tools/ui
        '';
        hash = "sha256-FHvd2bMvBc9EXrJEzu8EN78oUVSLcOKYCc0232V+L4A=";
      };
      postInstall = builtins.replaceStrings
        ["cp bin/rpc-server $out/bin/llama-rpc-server"]
        ["cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server"]
        old.postInstall;
      # vGPU guest driver libs (libcuda.so.1 etc.) are outside nixpkgs'
      # closure (grid driver from vgpu-guest.nix); NixOS has no working
      # ld.so.cache, so bake the grid lib dir into the rpath of every ELF
      # (libggml-cuda.so is what actually links libcuda.so.1; the fixup's
      # rpath-shrink keeps entries that resolve a needed library).
      postFixup = (old.postFixup or "") + ''
        for f in $out/bin/* $out/lib/*.so*; do
          [ -e "$f" ] || continue
          patchelf --add-rpath ${config.local.nvidiaGridLib} "$f" 2>/dev/null || true
        done
      '';
    }))

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];
}
