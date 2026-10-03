{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  bison,
  flex,
  # engine dependencies
  boost,
  fmt,
  spdlog,
  oniguruma,
  ffmpeg_4,
  jxrlib,
  libarchive,
  libxml2,
  libjpeg_turbo,
  libwebp,
  libvorbis,
  opusfile,
  openal-soft,
  opencv,
  lz4,
  zstd,
  zlib,
  minizip,
  argparse,
  glm,
  # provided through cocos2d-x but needed on the CMake search path
  box2d,
  bullet,
  glfw,
  libwebsockets,
  libtiff,
  glew,
  freetype,
  openssl,
  libpng,
  curl,
  sqlite,
  # platform libs
  libX11,
  libXi,
  libXxf86vm,
  libXrandr,
  libXinerama,
  libXcursor,
  libXmu,
  libGLU,
  gl2ps,
  libzip,
  fontconfig,
  gtk3,
  mesa,
  libGL,
  callPackage,
}:

let
  cocos2d-x = callPackage ./cocos2d-x.nix { };
  sevenzip = callPackage ./7zip.nix { };
  blend2d = callPackage ./blend2d.nix { };
  cocosShims = callPackage ./cocos-cmake-shims.nix { };
  uchardet = callPackage ../krkr2-next/uchardet.nix { };
  libunrar = callPackage ../krkr2-next/libunrar.nix { };
in

stdenv.mkDerivation {
  pname = "krkr2-emu";
  version = "1.5.0-unstable";

  src = fetchFromGitHub {
    owner = "2468785842";
    repo = "krkr2";
    rev = "dca7264572a63e753c1b07ca7053513d1751ce70";
    hash = "sha256-JB7rXoi/nVT2yxWDtooTKnlhXOwUHZxhHnox6Qf5F3o=";
  };

  patches = [
    ./patches/krkr2-linux-fixes.patch
    # Kirikiri "scrambled" scripts (FE FE <mode> FF FE): these re-packed titles
    # ship their .tjs/.ks bit-scrambled, and the loader skipped only 4 header
    # bytes, shifting every UTF-16 code unit by one so the parser saw garbage.
    ./patches/kirikiri-scrambled-script.patch
    # psbfile's load() used a file-local PSBMedia pointer that initPSBMedia()
    # (a different translation unit) never initialised -> null deref crash.
    ./patches/psbfile-storage-media.patch
    # `krkr2 data.xp3` failed with "Error opening archive": a bare relative
    # path is treated as a storage name, so resolve it against the cwd first.
    ./patches/launcher-relative-path.patch
    # Yuzusoft scenario containers are "mdf\0" (lowercase) + zlib; the MDF
    # signature check was case-sensitive, so loading a save failed with
    # "Not a valid PSB file" when it parsed the scene file.
    ./patches/psbfile-mdf-signature.patch
    # A transition handler from a Windows-only plugin (yuzuex.dll provides
    # "wave") falls back to crossfade, but the engine popped a modal warning
    # that blocked the transition and left the frame blank. Log it instead.
    ./patches/transition-missing-handler-log.patch
  ];

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    bison
    flex
  ];

  buildInputs = [
    cocos2d-x
    sevenzip
    blend2d
    cocosShims
    uchardet
    libunrar
    boost
    fmt
    spdlog
    oniguruma
    ffmpeg_4
    jxrlib
    libarchive
    libxml2
    libjpeg_turbo
    libwebp
    libvorbis
    opusfile
    openal-soft
    opencv
    lz4
    zstd
    zlib
    minizip
    argparse
    glm
    box2d
    bullet
    glfw
    libwebsockets
    libtiff
    glew
    freetype
    openssl
    libpng
    curl
    sqlite
    libX11
    libXi
    libXxf86vm
    libXrandr
    libXinerama
    libXcursor
    libXmu
    libGLU
    gl2ps
    libzip
    fontconfig.lib
    fontconfig.dev
    gtk3
    mesa
    libGL
  ];

  # nixpkgs keeps bullet's headers under include/bullet, and blend2d's public
  # header lives at include/blend2d.h.
  env.CPLUS_INCLUDE_PATH = "${bullet}/include/bullet:${bullet}/include:${blend2d}/include";
  env.C_INCLUDE_PATH = "${blend2d}/include";

  env.CMAKE_PREFIX_PATH = lib.concatStringsSep ":" [
    "${cocos2d-x}/share/cocos2dx"
    "${sevenzip}/share/7zip"
    "${blend2d}"
    "${cocosShims}"
    "${box2d}"
    "${glfw.dev}"
    "${libwebsockets.dev}"
    "${libtiff.dev}"
    "${glew.dev}"
    "${libjpeg_turbo.dev}"
    "${openal-soft}"
    "${libwebp}"
    "${freetype.dev}"
    "${openssl.dev}"
    "${zlib.dev}"
    "${libpng.dev}"
    "${curl.dev}"
    "${sqlite.dev}"
  ];

  cmakeFlags = [
    "-DBUILD_TOOLS=OFF"
    "-DENABLE_TESTS=OFF"
  ];

  # cocos2d-x's bundled FMOD reports SONAME libfmod.so.6 but the archive ships
  # only unversioned files; provide the versioned names.
  postInstall = ''
    # The upstream install rules only install the engine libraries/headers;
    # install the application itself and its cocos resources.
    install -Dm755 bin/krkr2/krkr2 $out/bin/krkr2
    if [ -d bin/krkr2/Resources ]; then
      cp -r bin/krkr2/Resources $out/bin/Resources
    fi

    mkdir -p $out/lib
    cp ${cocos2d-x}/share/cocos2dx/linux-specific/fmod/prebuilt/64-bit/libfmod*.so $out/lib/
    ln -sf libfmod.so $out/lib/libfmod.so.6
    ln -sf libfmodL.so $out/lib/libfmodL.so.6
  '';

  meta = with lib; {
    description = "KrKr2 Emulator: cross-platform KiriKiri2 runtime (cocos2d-x front end)";
    homepage = "https://github.com/2468785842/krkr2";
    license = licenses.bsd3;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "krkr2";
  };
}
