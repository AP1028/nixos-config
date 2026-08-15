{
  pkgs,
  config,
  inputs,
  lib,
  ...
}: let
  # GPUs here are Tesla P40 via NVIDIA vGPU (mdev "nvidia-53", grid driver
  # 535.309.01). The CUDA arch list still carries sm_61 for the P40 plus
  # sm_75/80/86/89/90 for consistency with the previous cluster build.
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

  # b10331: DeepSeek V4 DSpark speculative decoding (PR #25784) + MXFP4
  # cluster support. Shared with the gpu-host build, but compiled against
  # CUDA 12.2 and linked against the vGPU guest driver's libcuda below.
  llamaCppRpc = ((cuda23.llama-cpp.override {
    cudaSupport = true;
    inherit cudaPackages;
  }).overrideAttrs (old: {
    version = "10331";
    src = pkgs.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      tag = "b10331";
      hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
      leaveDotGit = true;
      postFetch = old.src.postFetch or null;
    };
    # stable split-graph uids so the RPC graph cache (GRAPH_RECOMPUTE) engages
    patches = (old.patches or [ ]) ++ [ ../../../packages/patches/rpc-graph-cache.patch ../../../packages/patches/rpc-dspark-draft-path.patch ../../../packages/patches/rpc-debug-tensor-name.patch ../../../packages/patches/rpc-dsv4-compressed-cpu.patch ../../../packages/patches/rpc-server-repack.patch ];
    # 23.11's postPatch substitutes ggml-metal.m (macOS-only) which does not
    # exist in the b10331 source -> drop it (metalSupport is false here).
    postPatch = "";
    # b10331 cmake leaves a CMAKE_BUILD_RPATH entry pointing into /build/
    # (kept by rpath-shrink since a needed lib resolves there); the
    # audit-tmpdir hook and daemon check would fail the build. The stale
    # entry is harmless (loader skips missing dirs); postFixup adds the
    # grid rpath anyway.
    noAuditTmpdir = true;
    forbiddenReferences = [];
    # b10331 moved the rpc-server to tools/rpc (target ggml-rpc-server) and
    # only installs it with LLAMA_TOOLS_INSTALL=ON. 23.11's llama-cpp has no
    # rpcSupport arg -> GGML_RPC here; arch list capped at sm_90 (nvcc 12.2).
    # b10331 hard-errors on deprecated LLAMA_CUBLAS which 23.11 passes ->
    # filter it, but re-enable CUDA via GGML_CUDA (filtering alone would
    # silently drop the CUDA backend from the build!).
    cmakeFlags = (builtins.filter (f: (builtins.match "-DLLAMA_CUBLAS.*" f) == null) old.cmakeFlags) ++ [
      "-DGGML_CUDA=ON"
      "-DLLAMA_TOOLS_INSTALL=ON"
      "-DGGML_RPC=ON"
      "-DCMAKE_CUDA_ARCHITECTURES=61;75;80;86;89;90"
      # 23.11's cuda toolkit ships no libcuda.so.1 (driver-owned); link
      # against the vGPU guest driver's libcuda at build time.
      "-DCMAKE_EXE_LINKER_FLAGS=-L${config.local.nvidiaGridLib} -Wl,-rpath-link,${config.local.nvidiaGridLib}"
      "-DCMAKE_SHARED_LINKER_FLAGS=-L${config.local.nvidiaGridLib} -Wl,-rpath-link,${config.local.nvidiaGridLib}"
    ];
    npmDeps = pkgs.fetchNpmDeps {
      name = "llama-cpp-10331-npm-deps";
      src = pkgs.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        tag = "b10331";
        hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
        leaveDotGit = true;
        postFetch = old.src.postFetch or null;
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
      (old.postInstall or "");
    # vGPU guest driver libs (libcuda.so.1 etc.) are outside nixpkgs'
    # closure (grid driver from vgpu-guest.nix); NixOS has no working
    # ld.so.cache, so bake the grid lib dir into the rpath of every ELF
    # (libggml-cuda.so is what actually links libcuda.so.1; the fixup's
    # rpath-shrink keeps entries that resolve a needed library).
    postFixup = (old.postFixup or "") + ''
      # 23.11 renames libs with a llama-cpp- prefix but SONAMEs stay
      # unprefixed -> symlink the soname names.
      for f in $out/bin/llama-cpp-lib*.so*; do
        b=$(basename "$f" | sed 's/^llama-cpp-//')
        [ -e "$(dirname "$f")/$b" ] || ln -sf "$(basename "$f")" "$(dirname "$f")/$b"
      done
      # 23.11 sets no install rpath -> bake in bin/lib (where the libs
      # live) plus the vGPU grid libs (libcuda.so.1 etc.).
      for f in $out/bin/* $out/lib/*.so*; do
        [ -e "$f" ] || continue
        patchelf --add-rpath $out/bin:$out/lib:${config.local.nvidiaGridLib} "$f" 2>/dev/null || true
      done
    '';
  }));
in {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    llamaCppRpc

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];

  # Expose the P40 vGPU to the gpu-host llama.cpp process over the 40G
  # interconnect. The main process passes --rpc 10.0.0.103:50052.
  systemd.services.llama-rpc-server = {
    description = "llama.cpp RPC server exposing the P40 vGPU";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "nvidia-devnodes.service"];
    wants = ["network-online.target"];
    requires = ["nvidia-devnodes.service"];
    path = [ llamaCppRpc ];
    serviceConfig = {
      User = "tianyixia";
      Group = "users";
      ExecStart = "${llamaCppRpc}/bin/llama-cpp-ggml-rpc-server -H 10.0.0.103 -p 50052 -d CUDA0";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 1048576;
    };
  };
}
