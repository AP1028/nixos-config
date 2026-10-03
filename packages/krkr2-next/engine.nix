{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  bison,
  flex,
  python3,
  boost,
  fmt,
  spdlog,
  oniguruma,
  ffmpeg_4,
  libhwy,
  vulkan-headers,
  vulkan-memory-allocator,
  spirv-tools,
  libvorbis,
  opusfile,
  libarchive,
  libxml2,
  SDL2,
  zstd,
  lz4,
  tinyxml-2,
  libpng,
  libjpeg_turbo,
  libwebp,
  openal-soft,
  freetype,
  opencv,
  libX11,
  libXrender,
  libexif,
  mesa,
  libGL,
  gtk3,
  pango,
  cairo,
  fontconfig,
  jxrlib,
  minizip,
  callPackage,
}:

let
  uchardet = callPackage ./uchardet.nix { };
  libunrar = callPackage ./libunrar.nix { };
  libgdiplusWithHeaders = callPackage ./libgdiplus-dev.nix { };
in

stdenv.mkDerivation {
  pname = "krkr2-engine";
  version = "1.5.0-unstable";

  src = fetchFromGitHub {
    owner = "reAAAq";
    repo = "KrKr2-Next";
    rev = "1abd1ed4e8aec7abd5d2524c3a9ad7886880602f";
    hash = "sha256-y5BFtHoTmlJh8qV1Jj87/WPiFadfKmkIIreeFlC9aiI=";
  };

  patches = [
    ./engine-build-fixes.patch
    # The engine reported a fixed 2048-wide virtual screen while the EGL
    # surface stayed 1280x720, so games laid out for the wrong size and the
    # viewport/readback covered only part of it (missing backgrounds, mirrored
    # UI). Derive the screen size from the actual surface instead.
    ./screen-size-fix.patch
    # The frame grab used the current GL viewport and whatever framebuffer was
    # bound, so once the game created its (power-of-two) layer textures the
    # readback returned a layer texture instead of the composed screen.
    ./frame-readback-fix.patch
  ];

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    bison
    flex
    python3
  ];

  buildInputs = [
    uchardet
    libunrar
    boost
    fmt
    spdlog
    oniguruma
    ffmpeg_4
    libhwy
    vulkan-headers
    vulkan-memory-allocator
    spirv-tools
    libvorbis
    opusfile
    libarchive
    libxml2
    SDL2
    zstd
    lz4
    tinyxml-2
    libpng
    libjpeg_turbo
    libwebp
    openal-soft
    freetype
    opencv
    libX11
    libXrender
    libexif
    mesa
    libGL
    gtk3
    pango
    cairo
    fontconfig
    jxrlib
    minizip
    libgdiplusWithHeaders
  ];

  # The engine_api shared library is the FFI bridge used by the Flutter app.
  cmakeFlags = [
    "-DLINUX=ON"
    "-DBUILD_TOOLS=OFF"
    "-DENABLE_TESTS=OFF"
    "-DBUILD_ENGINE_API=ON"
    "-DBUILD_LINUX_STANDALONE=OFF"
  ];

  # The visual module needs GL headers at runtime configuration only.

  installPhase = ''
    runHook preInstall
    install -Dm755 bridge/engine_api/libengine_api.so $out/lib/libengine_api.so
    runHook postInstall
  '';

  meta = with lib; {
    description = "KiriKiri2 engine rebuilt on Flutter + ANGLE (KrKr2-Next native engine library)";
    homepage = "https://github.com/reAAAq/KrKr2-Next";
    license = with licenses; [ mit ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
