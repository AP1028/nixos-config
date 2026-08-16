# NixOS support for the vLLM-2080Ti-Definitive runtime on gpu-host.
#
# The fork's build.sh expects a Debian/Ubuntu-style CUDA tree:
#   $CUDA_HOME/targets/x86_64-linux/lib/{libcudart_static.a,...}
# nixpkgs' cudatoolkit uses a flat merged layout, so this module builds a
# tiny compatibility derivation and exposes it as /etc/vllm-cuda-home.
#
# It also installs the pinned Nix compiler/tooling so the fork's pip/uv build
# never needs the host's too-new default GCC.  The vLLM runtime itself stays
# inside ~/vLLM-2080Ti-Definitive/.venv (a source-built Python venv), because
# the fork is validated against PyTorch 2.11.0+cu128 wheels rather than the
# nixpkgs torch package.
{
  config,
  pkgs,
  ...
}: let
  cuda = pkgs.cudaPackages.cudatoolkit;

  vllmCudaHome = pkgs.runCommand "vllm-2080ti-cuda-home" {} ''
    mkdir -p "$out/targets/x86_64-linux"
    ln -s "${cuda}/bin" "$out/bin"
    ln -s "${cuda}/include" "$out/include"
    ln -s "${cuda}/lib" "$out/lib"
    ln -s "${cuda}/lib" "$out/lib64"
    ln -s "${cuda}/lib" "$out/targets/x86_64-linux/lib"
    ln -s "${cuda}/nvvm" "$out/nvvm"
  '';
in {
  environment.systemPackages = [
    # Toolchain used by ~/vLLM-2080Ti-Definitive/build.sh.
    vllmCudaHome
    pkgs.uv
    pkgs.gcc14
    pkgs.cmake
    pkgs.ninja
  ];

  # Stable path for launcher/build wrappers:
  #   CUDA_HOME=/etc/vllm-cuda-home
  environment.etc."vllm-cuda-home".source = vllmCudaHome;
}
