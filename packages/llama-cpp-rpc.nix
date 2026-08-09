# llama.cpp with Vulkan (RADV) and RPC support.
#
# Both AMD GPUs (RX 560 / gfx803, RX 5600XT / gfx1010) are driven through the
# Vulkan backend provided by mesa RADV. Modern llama.cpp requires ROCm >= 6.1,
# which dropped gfx803, so the pinned ROCm 5.7.1 toolchain can no longer build
# a current llama.cpp (b4140 predates MXFP4); Vulkan covers both cards using
# the plain amdgpu kernel driver.
{
  lib,
  stdenv,
  cmake,
  fetchFromGitHub,
  shaderc,
  vulkan-headers,
  vulkan-loader,
  ninja,
  pkg-config,
  git,
  ...
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-rpc";
  version = "10133";

  src = fetchFromGitHub {
    owner = "ggerganov";
    repo = "llama.cpp";
    rev = "refs/tags/b${finalAttrs.version}";
    hash = "sha256-gA48mGXrjZUfxesTivDPU7enQFKHzpRC/bmodtWHI0s=";
    leaveDotGit = true;
    postFetch = ''
      git -C "$out" rev-parse --short HEAD > $out/COMMIT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };

  # RPC servers must repack quantized weights (mxfp4, ...) into the
  # interleaved layouts used by the fast CPU GEMV kernels, otherwise
  # RPC-served layers run the slow plain vec_dot path (~2-4x slower).
  patches = [
    ./patches/rpc-repack.patch
  ];

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git
  ];

  buildInputs = [
    shaderc
    vulkan-headers
    vulkan-loader
  ];

  preConfigure = ''
    prependToVar cmakeFlags "-DLLAMA_BUILD_COMMIT:STRING=$(cat COMMIT)"
  '';

  cmakeFlags = let
    inherit (lib) cmakeBool cmakeFeature;
  in [
    (cmakeBool "GGML_NATIVE" false) # -march=native would make builds non-deterministic
    (cmakeBool "LLAMA_BUILD_EXAMPLES" false)
    (cmakeBool "LLAMA_BUILD_SERVER" true)
    (cmakeBool "LLAMA_BUILD_TESTS" false)
    (cmakeBool "BUILD_SHARED_LIBS" true)
    (cmakeBool "GGML_CPU_ALL_VARIANTS" true) # AVX2 etc. for the Kaby Lake CPU backend
    (cmakeBool "GGML_BACKEND_DL" true)
    (cmakeBool "GGML_VULKAN" true)
    (cmakeBool "GGML_RPC" true)
    (cmakeBool "CMAKE_SKIP_BUILD_RPATH" true)
    (cmakeFeature "LLAMA_BUILD_NUMBER" finalAttrs.version)
  ];

  # nixpkgs postInstall copies bin/rpc-server, but llama.cpp b10000+ installs
  # it as ggml-rpc-server; point the rename at the installed path instead.
  postInstall = ''
    mkdir -p $out/include
    cp $src/include/llama.h $out/include/
    cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server
  '';

  meta = with lib; {
    description = "llama.cpp with Vulkan (RADV) and RPC support (RX 560 / RX 5600XT)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    mainProgram = "llama-cli";
    platforms = platforms.linux;
  };
})
