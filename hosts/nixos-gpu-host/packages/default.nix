{
  pkgs,
  config,
  inputs,
  lib,
  ...
}: let
  # llama.cpp b10442 = newer DSV4/DSpark tree, retried after fixing the RPC
  # graph-cache patch to stop poisoning CUDA graph uids.
  #
  # This build is independent from the gpu-vm build: gpu-host uses the
  # current nixpkgs-stable CUDA toolkit (driver 595.x, sm_75 for Turing).
  # The P40 (sm_61) has its own nixos-23.11 CUDA 12.2 build on gpu-vm;
  # RPC only ships graph metadata/activations between hosts, not cubins.
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

    # Same five RPC/DSV4 patches, all verified to apply to b10442.
    patches = (old.patches or [ ]) ++ [
      ../../../packages/patches/rpc-graph-cache.patch
      ../../../packages/patches/rpc-dspark-draft-path.patch
      ../../../packages/patches/rpc-debug-tensor-name.patch
      ../../../packages/patches/rpc-dsv4-compressed-cpu.patch
      ../../../packages/patches/rpc-server-repack.patch
    ];

    # Our fetchFromGitHub source has no .git/COMMIT file, so write the build
    # commit string directly instead of the package default $(cat COMMIT).
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
    # ngl=15 is the largest stable split with the b10331 CUDA graph bug
    # workaround below. With graphs enabled, long prompts hit a CUDA illegal
    # memory access in the DSV4 path; disabling only CUDA graphs avoids the
    # crash and keeps output correct. (Disabling fusion as well produced
    # garbage tokens, so fusion stays enabled.)
    environment = {
      GGML_CUDA_DISABLE_GRAPHS = "1";
    };
    serviceConfig = {
      User = "tianyixia";
      Group = "users";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "1800";
      LimitNOFILE = 1048576;
      # 15 pipeline layers: P40 5 layers, each 2080 Ti 5 layers; CPU/RAM keeps
      # the remaining 28 layers. -sm tensor is NOT implemented for deepseek4
      # in llama.cpp b10331.
      ExecStart = "${llamaCppDsv4}/bin/llama-server -m /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf --host 0.0.0.0 --port 8080 --rpc 10.0.0.103:50052 -ngl 15 -sm layer -ts 1,1,1 -c 4096 -b 256 -ub 128 --no-webui";
    };
  };
}
