# llama.cpp runtime for the gpu-vm long-context tier.
#
# The vLLM fork's linear-attention prefill is quadratic (state rescan per
# chunk), so windows past ~200k run on llama.cpp (chunked scan, linear
# prefill). This module builds llama.cpp from a pinned upstream revision with
# the local tuning patches applied, CUDA sm75 + NCCL for TP=2 tensor split.
#
# Patches (see llamacpp-tuning.patch):
#   - ggml-cuda/convert.cu    : fix quantized-KV (q4_0/q8_0) prefill slowness
#                               (upstream PR #27140, unmerged)
#   - src/models/{qwen35,qwen35moe,qwen3next,kimi-linear}.cpp
#                             : fix linear-attention state corruption on
#                               multi-GPU graph partitioning (PR #22661)
#   - tools/server/server-context.cpp
#                             : remove the per-slot train-context cap so an
#                               explicit -c + YaRN is honored; expose
#                               max_model_len/context_length in /v1/models so
#                               OpenAI clients (opencode) see the real window
{
  config,
  pkgs,
  lib,
  ...
}: let
  cuda = pkgs.cudaPackages;

  llamaSrc = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "6fe74980162af0ed5e559870d5deccafaa034e7c";
    sha256 = "1bqsx7blnqkkz5znawd1h7rr69i08zcj83v1s4g0fbmpngmrci6h";
  };

  llamacpp = pkgs.stdenv.mkDerivation {
    pname = "llama-cpp-tuned";
    version = "6fe7498";

    src = llamaSrc;
    patches = [./llamacpp-tuning.patch];

    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.gcc14 # CUDA 12.9 nvcc rejects the host's default (too-new) GCC
      cuda.cudatoolkit
      pkgs.autoAddDriverRunpath # real driver libcuda in the runpath (no stub)
    ];
    buildInputs = [
      cuda.cudatoolkit
      cuda.nccl
    ];

    cmakeFlags = [
      "-DGGML_CUDA=ON"
      "-DGGML_CUDA_NCCL=ON"
      "-DGGML_CUDA_FA_ALL_QUANTS=ON"
      "-DGGML_CUDA_MMVQ=ON"
      "-DGGML_CUDA_POOL_ALLOC=ON"
      "-DCMAKE_CUDA_ARCHITECTURES=75"
      "-DGGML_NATIVE=OFF"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DLLAMA_BUILD_TESTS=OFF"
      "-DLLAMA_BUILD_EXAMPLES=ON"
    ];

    env = {
      CC = "${pkgs.gcc14}/bin/gcc";
      CXX = "${pkgs.gcc14}/bin/g++";
      CUDAHOSTCXX = "${pkgs.gcc14}/bin/g++";
      CUDACXX = "${cuda.cudatoolkit}/bin/nvcc";
      NCCL_ROOT = "${cuda.nccl}";
    };

    meta = with lib; {
      description = "llama.cpp with gpu-vm tuning patches (CUDA sm75 + NCCL)";
      mainProgram = "llama-server";
    };
  };
in {
  environment.systemPackages = [llamacpp];

  # The vllm-manager spawns the long-context backend from this binary.
  systemd.services.vllm-manager.environment.LLAMACPP_BIN =
    "${llamacpp}/bin/llama-server";
}
