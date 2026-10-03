{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  bison,
  # cocos2d-x externals
  box2d,
  bullet,
  libuv,
  libwebsockets,
  curl,
  bzip2,
  freetype,
  libjpeg_turbo,
  libwebp,
  libtiff,
  openssl,
  sqlite,
  zlib,
  libpng,
  glfw,
  # platform libs for the Linux port
  libX11,
  libXi,
  libXxf86vm,
  libXrandr,
  libXinerama,
  libXcursor,
  libXmu,
  libGLU,
  glew,
  gl2ps,
  libzip,
  fontconfig,
  gtk3,
  openal-soft,
  libogg,
  libvorbis,
  mesa,
  libGL,
  callPackage,
}:

let
  # vcpkg-style CMake configs that nixpkgs does not ship
  shims = callPackage ./cocos-cmake-shims.nix { };
in

stdenv.mkDerivation (finalAttrs: {
  pname = "cocos2d-x";
  version = "3.17.2";

  src = fetchurl {
    url = "https://github.com/cocos2d/cocos2d-x/archive/refs/tags/cocos2d-x-${finalAttrs.version}.tar.gz";
    hash = "sha512-stWsloIxiSw5qVPYLpeRwhgrDbzspXkWR7stqtJYE0clOGyesdMt4UhGXYjS2TKynyQa8PX0tObZ2A2WhPUx+g==";
  };

  # Prebuilt third-party sources/libs the cocos2d-x build expects in external/
  thirdParty = fetchurl {
    url = "https://github.com/2468785842/cocos2d-x-3rd-party-libs-bin/archive/refs/heads/v3.tar.gz";
    hash = "sha512-RAhsDrieMIXq8eVbMm1rkZ2Dn5W/VoaPjtpE3oClJsiRDmWHgY7iNkx7wTmwMs/bO8NcHi921idbQix057+GFA==";
  };

  # The emulator repo vendors the vcpkg port (patched CMakeLists + patches)
  port = fetchFromGitHub {
    owner = "2468785842";
    repo = "krkr2";
    rev = "dca7264572a63e753c1b07ca7053513d1751ce70";
    hash = "sha256-JB7rXoi/nVT2yxWDtooTKnlhXOwUHZxhHnox6Qf5F3o=";
  };

  patches = [ ./patches/cocos-linux-fixes.patch ];

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
    bison
  ];

  buildInputs = [
    shims
    box2d
    bullet
    libuv
    libwebsockets
    curl
    bzip2
    freetype
    libjpeg_turbo
    libwebp
    libtiff
    openssl
    sqlite
    zlib
    libpng
    glfw
    libX11
    libXi
    libXxf86vm
    libXrandr
    libXinerama
    libXcursor
    libXmu
    libGLU
    glew
    gl2ps
    libzip
    fontconfig.lib
    fontconfig.dev
    gtk3
    openal-soft
    libogg
    libvorbis
    mesa
    libGL
  ];

  # nixpkgs' bullet keeps headers under include/bullet, while the sources
  # include them as <LinearMath/...>.
  env.CPLUS_INCLUDE_PATH = "${bullet}/include/bullet:${bullet}/include";

  # Unpack explicitly: the GitHub tarball's root directory must be stripped,
  # which the default unpacker handles inconsistently for plain fetchurl srcs.
  unpackPhase = ''
    runHook preUnpack
    mkdir cocos
    tar xzf $src -C cocos --strip-components=1
    cd cocos
    runHook postUnpack
  '';

  postUnpack = ''
    # the vcpkg port overlays its own CMakeLists and helper modules
    portDir="$NIX_BUILD_TOP/vcpkg-port"
    mkdir -p "$portDir"
    cp -r ${finalAttrs.port}/vcpkg/ports/cocos2dx/. "$portDir/"

    cp "$portDir/cocos2dx-config.cmake.in" ./
    cp "$portDir/patch/cocos2d-x/CMakeLists.txt" ./CMakeLists.txt
    cp "$portDir/patch/cocos2d-x/cocos/CMakeLists.txt" ./cocos/CMakeLists.txt
    cp "$portDir/patch/cocos2d-x/cmake/Modules/CocosBuildHelpers.cmake" \
       ./cmake/Modules/CocosBuildHelpers.cmake
    cp "$portDir/patch/cocos2d-x/cmake/Modules/CocosConfigDepend.cmake" \
       ./cmake/Modules/CocosConfigDepend.cmake

    # extract the third-party sources into external/
    mkdir -p external
    tar xzf ${finalAttrs.thirdParty} -C external --strip-components=1
    cp "$portDir/patch/cocos2d-x/external/CMakeLists.txt" external/CMakeLists.txt

    # apply the port's patch series (root-relative)
    for p in "$portDir"/patch/*.patch; do
      patch -p1 --forward --batch < "$p"
    done
  '';

  # The port's build expects the vcpkg-style config layout in share/cocos2dx;
  # additionally expose it on the standard CMake search path.
  cmakeFlags = [
    "-DBUILD_TESTS=OFF"
    "-DBUILD_JS_LIBS=OFF"
    "-DBUILD_LUA_LIBS=OFF"
  ];

  env.CMAKE_PREFIX_PATH = lib.concatStringsSep ":" [
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

  postInstall = ''
    # find_package(cocos2dx CONFIG) should also work from lib/cmake, but the
    # port's config computes its import prefix relative to its own location,
    # so forward to the real config in share/cocos2dx instead of copying it.
    mkdir -p $out/lib/cmake/cocos2dx
    # FMOD's SONAME is libfmod.so.6 but the archive ships unversioned files.
    for dir in $out/share/cocos2dx/linux-specific/fmod/prebuilt/64-bit \
               $out/lib/cmake/cocos2dx/linux-specific/fmod/prebuilt/64-bit; do
      if [ -d "$dir" ]; then
        ln -sf libfmod.so "$dir/libfmod.so.6"
        ln -sf libfmodL.so "$dir/libfmodL.so.6"
      fi
    done

    cat > $out/lib/cmake/cocos2dx/cocos2dx-config.cmake <<'EOF'
include("''${CMAKE_CURRENT_LIST_DIR}/../../../share/cocos2dx/cocos2dx-config.cmake")
EOF
  '';

  meta = with lib; {
    description = "cocos2d-x 3.17.2 built for the KrKr2 emulator (Linux)";
    homepage = "https://www.cocos2d-x.org";
    license = licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
