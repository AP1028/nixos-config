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
    # Games that ship their own fonts register them through the Windows-only
    # "addFont.dll" plugin; without it they fall back to a substituted font
    # (wrong glyph shapes and advances, or missing-glyph dots when no CJK font
    # is present at all). This provides that plugin as an internal module.
    ./addfont-plugin.patch
    # Pick a Regular-weight face as the default font. Collections and variable
    # fonts also contain Thin/Light instances, and the old "last name wins"
    # rule could select one of those, which renders hairline-looking text.
    ./font-default-regular.patch
    # Make the D3D adaptor expose the captured canvas' geometry/buffer instead
    # of answering zeroes, tolerate the motion drawing calls it forwards, and
    # keep the game alive when the affine image loader asks for something the
    # canvas does not implement.
    ./d3d-adaptor-canvas.patch
    # Games ask for motionplayer_nod3d.dll (the non-Direct3D motion player) and
    # fall back to the stubbed D3D path when it is missing. Our motion player is
    # that non-D3D implementation, so route the name to it.
    ./motionplayer-nod3d.patch
    # PSB layer positions are centre-relative (a full-screen 1920x1080 layer is
    # at -960,-540) and must be shifted by half the composition size, otherwise
    # the motion art is composited off-screen.
    ./motion-psb-center.patch
    # Without a display, GTK message boxes abort the process; log instead.
    ./messagebox-headless.patch
    # Layer.loadImages raised for images the original multi-image plugin would
    # have resolved; games call it from their affine-layer setup, where the
    # exception tore down the whole scene. Log and leave the layer as it is.
    ./layer-loadimages-tolerant.patch
    # Port the tree's layerExDraw plugin (which the game loads by name for its
    # affine/raster layers) to Linux/libgdiplus and link it in. It only builds
    # with KRKR_ENABLE_LAYEREX_DRAW, which cmakeFlags now sets.
    ./layerex-draw-linux.patch
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
    # Yuzusoft titles load layerExDraw.dll for their affine/raster layers (the
    # game asks for it by name and logs "layerExRaster plugin not loaded"-style
    # failures otherwise). The cross-platform sources are in the tree and only
    # build with this option; they need libgdiplus, which is already an input.
    "-DKRKR_ENABLE_LAYEREX_DRAW=ON"
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
