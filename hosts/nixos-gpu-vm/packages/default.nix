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
      postInstall = builtins.replaceStrings
        ["cp bin/rpc-server $out/bin/llama-rpc-server"]
        ["cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server"]
        old.postInstall;
    }))

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];
}
