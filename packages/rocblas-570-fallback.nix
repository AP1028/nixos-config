# rocBLAS 5.7.1 rebuilt with the patched Tensile so that:
#   - gfx803 (RX 560): uses the reference (fallback) kernels — the Tensile 5.7
#     asm kernels are numerically broken on Polaris (known since ROCm 3.7)
#   - gfx1010 (RX 5600 XT): gets a lazy library at all (Tensile 5.7 ships none)
# Only the two needed arch groups are built to keep the build time sane.
{
  lib,
  stdenv,
  fetchFromGitHub,
  rocmUpdateScript,
  rocm-cmake,
  clr,
  clang,
  llvm,
  bintools,
  cmake,
  python3,
  python3Packages,
  msgpack,
  libxml2,
  tensile,
  gpuTargets ? [
    "gfx803"
    "gfx1010"
  ],
}:

let
  # Build rocblas for a specific set of GPU targets.
  rocblasFor = gpuTargets: stdenv.mkDerivation (finalAttrs: {
    pname = "rocblas";
    version = "5.7.1";

    src = fetchFromGitHub {
      owner = "ROCmSoftwarePlatform";
      repo = "rocBLAS";
      rev = "rocm-${finalAttrs.version}";
      hash = "sha256-3wKnwvAra8u9xqlC05wUD+gSoBILTVJFU2cIV6xv3Lk=";
    };

    nativeBuildInputs = [
      cmake
      rocm-cmake
      clr
      llvm
      bintools
    ];

    buildInputs = [
      python3
      msgpack
      libxml2
      python3Packages.msgpack
      python3Packages.joblib
      python3Packages.pyyaml
    ];

    # Tensile probes the assembler (AsmCaps) and assembles asm kernels; the
    # nix store does not look like /opt/rocm, so point at the real pieces.
    # ld.lld must be on PATH for the probe to succeed.
    env = {
      ROCM_PATH = "${clr}";
      TENSILE_ROCM_ASSEMBLER_PATH = "${clang}/bin/clang++";
      TENSILE_ROCM_OFFLOAD_BUNDLER_PATH = "${clang}/bin/clang-offload-bundler";
    };

    cmakeFlags = [
      "-DCMAKE_C_COMPILER=hipcc"
      "-DCMAKE_CXX_COMPILER=hipcc"
      "-Dpython=python3"
      "-DAMDGPU_TARGETS=${lib.concatStringsSep ";" gpuTargets}"
      "-DBUILD_WITH_TENSILE=ON"
      "-DCMAKE_INSTALL_BINDIR=bin"
      "-DCMAKE_INSTALL_LIBDIR=lib"
      "-DCMAKE_INSTALL_INCLUDEDIR=include"
      "-DVIRTUALENV_HOME_DIR=/build/source/tensile"
      "-DTensile_TEST_LOCAL_PATH=/build/source/tensile"
      "-DTensile_ROOT=/build/source/tensile/${python3.sitePackages}/Tensile"
      "-DTensile_LOGIC=asm_full"
      "-DTensile_CODE_OBJECT_VERSION=default"
      "-DTensile_SEPARATE_ARCHITECTURES=ON"
      "-DTensile_LAZY_LIBRARY_LOADING=ON"
      "-DTensile_LIBRARY_FORMAT=msgpack"
    ];

    postPatch =
      (lib.optionalString (finalAttrs.pname != "rocblas") ''
        # Return early and install tensile files manually
        substituteInPlace library/src/CMakeLists.txt \
          --replace "set_target_properties( TensileHost PROPERTIES OUTPUT_NAME" "return()''\nset_target_properties( TensileHost PROPERTIES OUTPUT_NAME"
      '')
      + (lib.optionalString (finalAttrs.pname == "rocblas") ''
        # Link the prebuilt Tensile files
        mkdir -p build/Tensile/library

        for path in ${gfx803} ${gfx1010} ${fallbacks}; do
          ln -s $path/lib/rocblas/library/* build/Tensile/library
        done

        unlink build/Tensile/library/TensileManifest.txt
      '')
      + ''
        # Tensile REALLY wants to write to the nix directory if we include it normally
        cp -a ${tensile} tensile
        chmod +w -R tensile

        # Rewrap Tensile
        substituteInPlace tensile/bin/{.t*,.T*,*} \
          --replace "${tensile}" "/build/source/tensile"

        substituteInPlace CMakeLists.txt \
          --replace "include(virtualenv)" "" \
          --replace "virtualenv_install(" "#virtualenv_install("
      '';

    postInstall =
      (lib.optionalString (finalAttrs.pname == "rocblas") ''
        ln -sf ${fallbacks}/lib/rocblas/library/TensileManifest.txt $out/lib/rocblas/library
      '')
      + (lib.optionalString (finalAttrs.pname != "rocblas") ''
        mkdir -p $out/lib/rocblas/library
        rm -rf $out/share
      '')
      + (lib.optionalString (finalAttrs.pname != "rocblas" && finalAttrs.pname != "rocblas-tensile-fallbacks") ''
        rm Tensile/library/{TensileManifest.txt,*_fallback.dat}
        mv Tensile/library/* $out/lib/rocblas/library
      '')
      + (lib.optionalString (finalAttrs.pname == "rocblas-tensile-fallbacks") ''
        mv Tensile/library/{TensileManifest.txt,*_fallback.dat} $out/lib/rocblas/library
      '');

    passthru.updateScript = rocmUpdateScript {
      name = finalAttrs.pname;
      owner = finalAttrs.src.owner;
      repo = finalAttrs.src.repo;
    };

    requiredSystemFeatures = [ "big-parallel" ];

    meta = with lib; {
      description = "BLAS implementation for ROCm platform";
      homepage = "https://github.com/ROCmSoftwarePlatform/rocBLAS";
      license = with licenses; [ mit ];
      maintainers = teams.rocm.members;
      platforms = platforms.linux;
    };
  });

  rocblas = rocblasFor gpuTargets;

  # The patched Tensile makes gfx803/gfx1010 fall back to the reference
  # kernels when generating the lazy library.
  gfx803 = (rocblasFor [ "gfx803" ]).overrideAttrs {
    pname = "rocblas-tensile-gfx803";
  };

  gfx1010 = (rocblasFor [ "gfx1010" ]).overrideAttrs {
    pname = "rocblas-tensile-gfx1010";
  };

  fallbacks = (rocblasFor gpuTargets).overrideAttrs {
    pname = "rocblas-tensile-fallbacks";
  };
in
rocblas
