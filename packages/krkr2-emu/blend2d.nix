{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
}:

# The emulator's layerex_draw plugin uses blend2d's pre-rename C++ API
# (getImage/makeIdentity/mapPoint/empty/getBoundingBox), which nixpkgs'
# current blend2d no longer provides. Pin the revision vcpkg builds.
stdenv.mkDerivation {
  pname = "blend2d";
  version = "0.21.0-unstable-2025-03-08";

  src = fetchFromGitHub {
    owner = "blend2d";
    repo = "blend2d";
    rev = "d2027ebfd6aaf53b190b6b3b497425fc85f14251";
    hash = "sha256-PXeu8FkwBIil8L9qM3B3gws0Lg3zigMKrlwVZNDPzeg=";
  };

  nativeBuildInputs = [
    cmake
    ninja
  ];

  cmakeFlags = [
    # nixpkgs' asmjit is newer than this blend2d revision expects, so build
    # without the optional JIT pipeline compiler.
    "-DBLEND2D_NO_JIT=ON"
    "-DBLEND2D_NO_FUTEX=OFF"
    "-DBLEND2D_STATIC=OFF"
  ];

  meta = with lib; {
    description = "2D vector graphics engine (pinned for the KrKr2 emulator)";
    homepage = "https://blend2d.com";
    license = licenses.zlib;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
