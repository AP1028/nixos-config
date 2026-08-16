{
  pkgs,
  config,
  inputs,
  lib,
  ...
}: let
  # llama.cpp b10442: newer than b10331, still has deepseek4/DSpark and the
  # same RPC protocol (5.0.0) as the b10331 rpc-server on gpu-vm. The goal of
  # this bump is to test whether the b10331 long-prompt CUDA illegal-memory
  # crash at -ngl>7 is fixed, so the GPUs can actually be filled.
  #
  # nixpkgs-stable 26.05 still packages b9190, which has no deepseek4 support,
  # so we continue to pin llama.cpp explicitly. The P40 (sm_61) has its own
  # nixos-23.11 CUDA 12.2 build on gpu-vm; RPC only ships graph
  # metadata/activations between hosts.
  llamaCppDsv4 = (pkgs.llama-cpp.override {
    cudaSupport = true;
    rpcSupport = true;
    cudaPackages = pkgs.cudaPackages;
  }).overrideAttrs (old: let
    b10442-src = pkgs.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      tag = "b10442";
      hash = "sha256-R47+47474rmh6pbatI0ucZXoqeMfGHL/geFklEUx/1E=";
    };
    oldCmakeFlagsWithoutCudaArch = builtins.filter
      (f: (builtins.match "-DCMAKE_CUDA_ARCHITECTURES.*" f) == null)
      old.cmakeFlags;
  in {
    version = "10442";
    src = b10442-src;

    # The same RPC/DSV4 patches apply cleanly to b10442 and are shared with
    # the gpu-vm build.
    patches = (old.patches or [ ]) ++ [
      ../../../packages/patches/rpc-graph-cache.patch
      ../../../packages/patches/rpc-dspark-draft-path.patch
      ../../../packages/patches/rpc-debug-tensor-name.patch
      ../../../packages/patches/rpc-dsv4-compressed-cpu.patch
      ../../../packages/patches/rpc-server-repack.patch
    ];

    # Our fetchFromGitHub source has no .git/COMMIT file, so write the build
    # commit string directly instead of the package default $(cat COMMIT).
    # Still build tools/ui, exactly like the base package.
    preConfigure = ''
      prependToVar cmakeFlags "-DLLAMA_BUILD_COMMIT:STRING=b10442"
      pushd tools/ui
      npm run build
      popd
    '';

    cmakeFlags = oldCmakeFlagsWithoutCudaArch ++ [
      # b10442 installs ggml-rpc-server only with LLAMA_TOOLS_INSTALL.
      "-DLLAMA_TOOLS_INSTALL=ON"
      # Bare-metal only has 2x 2080 Ti (Turing sm_75). Building only the
      # arch that can run here keeps CUDA compile time and closure smaller.
      "-DCMAKE_CUDA_ARCHITECTURES=75"
    ];

    npmDeps = pkgs.fetchNpmDeps {
      name = "llama-cpp-10442-npm-deps";
      src = b10442-src;
      patches = [ ../../../packages/patches/rpc-graph-cache.patch ];
      preBuild = ''
        pushd tools/ui
      '';
      hash = "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
    };

    # b10442 installs ggml-rpc-server (not bin/rpc-server like b9190).
    postInstall = ''
      mkdir -p $out/include
      cp $src/include/llama.h $out/include/
      cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server
    '';
  });
in {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    llamaCppDsv4

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];

  # Optional persistent OpenAI-compatible server for the cluster. It is NOT
  # auto-enabled (wantedBy is empty) because a 155 GB MXFP4 model load takes
  # minutes and should be started explicitly when needed:
  #   systemctl start llama-server
  # The flags below are kept in sync with the best measured split; adjust
  # -ngl / -sm / -ts only after re-running llama-bench.
  systemd.services.llama-server = {
    description = "llama.cpp server for deepseek-v4-flash-0731 (RPC cluster)";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = lib.mkForce [];
    path = [ llamaCppDsv4 pkgs.curl ];
    # ngl=7 is the maximum layer split that is stable for long real prompts
    # with b10331 on this GPU mix. Higher ngl (e.g. 15) loads and runs short
    # prompts, but long prompts still hit a CUDA illegal memory access in the
    # fused DSV4 path. Disabling CUDA graph/fusion makes the crash go away but
    # produces garbage output, so we do NOT use that workaround.
    serviceConfig = {
      User = "tianyixia";
      Group = "users";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "1800";
      LimitNOFILE = 1048576;
      # Best measured stable split: 7 layers in pipeline mode, distributed
      # equally across RPC P40 + 2x 2080 Ti. -sm tensor is NOT implemented
      # for deepseek4 in llama.cpp b10331; ngl=8+ crashes on real prompts.
      ExecStart = "${llamaCppDsv4}/bin/llama-server -m /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf --host 0.0.0.0 --port 8080 --rpc 10.0.0.103:50052 -ngl 7 -sm layer -ts 1,1,1 -c 4096 -b 256 -ub 128 --no-webui";
    };
  };
}
