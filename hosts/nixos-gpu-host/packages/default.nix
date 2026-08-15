{
  pkgs,
  config,
  inputs,
  ...
}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    # Current stable llama.cpp with CUDA + RPC support. No nixos-23.11 pin and
    # no vGPU grid-driver rpath workarounds are needed on bare-metal Turing.
    (llama-cpp.override {
      cudaSupport = true;
      rpcSupport = true;
      cudaPackages = pkgs.cudaPackages;
    })

    # gguf model tooling (metadata scans, split computation, ...)
    (python3.withPackages (ps: [ps.numpy]))
  ];
}
