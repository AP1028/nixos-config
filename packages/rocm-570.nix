# ROCm 5.7.1 package set (from the pinned nixos-23-11 input) with a rebuilt
# rocBLAS whose Tensile lazy libraries use the reference (fallback) kernels:
#   - gfx803 (RX 560): Tensile 5.7 asm kernels are numerically broken
#   - gfx1010 (RX 5600 XT): Tensile 5.7 ships no lazy library at all
{
  oldPkgs,
}:

let
  patchedTensile = oldPkgs.rocmPackages.tensile.overrideAttrs (o: {
    patches = (o.patches or [ ]) ++ [
      ./tensile-1862.patch
      # The TENSILE_LIBRARY_TARGET copy step lists manifest files the patched
      # writer no longer produces (fallback kernels are written into the arch
      # Kernels.so instead); tolerate missing files.
      ./tensile-copy-tolerant.patch
    ];
  });

  rocblas = oldPkgs.callPackage ./rocblas-570-fallback.nix {
    tensile = patchedTensile;
    clr = oldPkgs.rocmPackages.clr;
    clang = oldPkgs.rocmPackages.llvm.clang-unwrapped;
    llvm = oldPkgs.rocmPackages.llvm.llvm;
    bintools = oldPkgs.rocmPackages.llvm.bintools;
    rocm-cmake = oldPkgs.rocmPackages.rocm-cmake;
    rocmUpdateScript = oldPkgs.rocmPackages.rocmUpdateScript or oldPkgs.rocmUpdateScript;
  };

  hipblas = oldPkgs.rocmPackages.hipblas.override {
    inherit rocblas;
  };
in
{
  inherit rocblas hipblas;
  clr = oldPkgs.rocmPackages.clr;
  rocm-runtime = oldPkgs.rocmPackages.rocm-runtime;
}
