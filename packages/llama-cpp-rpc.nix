# llama.cpp built with HIP (ROCm 5.7.1) and RPC support.
#
# ROCm >= 6 dropped gfx803 (Polaris / RX 560), so this uses the ROCm 5.7.1
# packages from the pinned nixos-23-11 input. The llama.cpp revision is
# pinned to 2024-10-09 (b4140-era): it supports both the RPC backend
# (merged May 2024) and ROCm 5.7. Both GPUs are compiled for natively:
#   - AMD RX 560 (Baffin, gfx803)
#   - AMD RX 5700 (Navi 10, gfx1010)
{
  lib,
  stdenv,
  cmake,
  fetchFromGitHub,
  makeWrapper,
  patchelf,
  rocmPackages,
  gpuTargets ? [
    "gfx803"
    "gfx1010"
  ],
}:

let
  rocmLibPath = lib.makeLibraryPath (with rocmPackages; [
    clr
    hipblas
    rocblas
    rocm-runtime
  ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-rpc";
  version = "b4140";

  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "c81f3bbb051f8b736e117dfc78c99d7c4e0450f6";
    hash = "sha256-26WgGpdGelzMIAULi/1S0ugNCSSB+HcyVW13dc1ZrJI=";
  };

  nativeBuildInputs = [
    cmake
    makeWrapper
    patchelf
  ];

  buildInputs = with rocmPackages; [
    clr
    hipblas
    rocblas
  ];

  patches = [
    # hipBLAS 5.7 (Tensile) can't run strided-batched GEMMs with batch > 16;
    # chunk them so prompt processing works on ROCm 5.7.
    ./llama-cpp-rpc-chunk-batched-gemm.patch
  ];

  cmakeFlags = [
    "-DGGML_HIPBLAS=ON"
    "-DGGML_RPC=ON"
    "-DLLAMA_RPC=ON"
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DAMDGPU_TARGETS=${lib.concatStringsSep ";" gpuTargets}"
    "-DCMAKE_C_COMPILER=hipcc"
    "-DCMAKE_CXX_COMPILER=hipcc"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  ];

  # With hipcc as the compiler (legacy path) the arch list is read from the
  # environment, not from the cmake cache.
  env.AMDGPU_TARGETS = lib.concatStringsSep ";" gpuTargets;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib
    for f in bin/*; do
      test -x "$f" || continue
      cp "$f" $out/bin/
    done
    for f in $(find . -name 'lib*.so' -type f); do
      cp "$f" $out/lib/
    done

    # hipcc adds its own RUNPATH (clr/glibc/clang) but cmake also appends the
    # build-tree dirs for the shared libs. Drop those and point at $out/lib.
    for f in $out/bin/* $out/lib/*.so; do
      rpath=$(patchelf --print-rpath "$f" || true)
      filtered=$(echo "$rpath" | tr ':' '\n' | grep -v '^/build' | paste -sd: -)
      patchelf --set-rpath "$filtered:$out/lib" "$f"
      case "$f" in
        $out/bin/*) wrapProgram "$f" --prefix LD_LIBRARY_PATH : "${rocmLibPath}" ;;
      esac
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "llama.cpp with HIP (ROCm 5.7) and RPC support (gfx803/gfx1010)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    mainProgram = "llama-cli";
    platforms = platforms.linux;
  };
})
