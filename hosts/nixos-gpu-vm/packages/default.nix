{
  pkgs,
  ...
}: let
  # Both GPUs here are Pascal (GTX 1060 / Tesla P40, sm_61). The default CUDA
  # arch list omits sm_61, so build llama.cpp against cudaPackages_12_9 (last
  # CUDA line with Pascal support; CUDA 13 dropped it) with sm_61 added.
  # rpcSupport compiles in the RPC backend + rpc-server for future llama RPC
  # work, but no RPC services/clients are configured yet.
  cudaPackages = pkgs.cudaPackages_12_9.overrideScope (final: prev: {
    flags = prev.flags // {
      cmakeCudaArchitecturesString = "61;75;80;86;89;90;100;103;120;121";
    };
  });
in {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    # nixpkgs postInstall copies bin/rpc-server, but llama.cpp b10000+ installs
    # it as ggml-rpc-server; point the rename at the installed path instead.
    ((llama-cpp.override {
      cudaSupport = true;
      rpcSupport = true;
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
      # only installs it with LLAMA_TOOLS_INSTALL=ON
      cmakeFlags = old.cmakeFlags ++ [ "-DLLAMA_TOOLS_INSTALL=ON" ];
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
    }))

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];
}
