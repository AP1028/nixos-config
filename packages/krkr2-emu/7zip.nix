{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  cmake,
  ninja,
  callPackage,
}:

let
  # The emulator repo vendors the vcpkg port (its own CMakeLists + config)
  port = fetchFromGitHub {
    owner = "2468785842";
    repo = "krkr2";
    rev = "dca7264572a63e753c1b07ca7053513d1751ce70";
    hash = "sha256-JB7rXoi/nVT2yxWDtooTKnlhXOwUHZxhHnox6Qf5F3o=";
  };

  arch =
    if stdenv.hostPlatform.isAarch64 then "arm64"
    else if stdenv.hostPlatform.isx86_64 then "x64"
    else "x86";
in

stdenv.mkDerivation {
  pname = "7zip-sdk";
  version = "24.09";

  src = fetchurl {
    url = "https://github.com/ip7z/7zip/archive/refs/tags/24.09.tar.gz";
    hash = "sha512-3AJB7ZaQeWVEVVCRLRFx/jIjClKZewiVWKTMc6Zi/GoXlA243LB5S4BSaJZImdnlpI3bRE6StW/SQ7uqF8IKHA==";
  };

  unpackPhase = ''
    runHook preUnpack
    mkdir 7zip
    tar xzf $src -C 7zip --strip-components=1
    cd 7zip
    cp ${port}/vcpkg/ports/7zip/CMakeLists.txt ./CMakeLists.txt
    cp ${port}/vcpkg/ports/7zip/7zip-config.cmake.in ./7zip-config.cmake.in
    runHook postUnpack
  '';

  sourceRoot = ".";

  nativeBuildInputs = [
    cmake
    ninja
  ];

  # the port's CMakeLists keys off vcpkg variables
  cmakeFlags = [
    "-DVCPKG_TARGET_IS_LINUX=ON"
    "-DVCPKG_TARGET_IS_WINDOWS=OFF"
    "-DVCPKG_TARGET_IS_OSX=OFF"
    "-DVCPKG_TARGET_ARCHITECTURE=${arch}"
  ];

  postInstall = ''
    # expose the config on the standard CMake search path as well
    mkdir -p $out/lib/cmake
    cp -r $out/share/7zip $out/lib/cmake/7zip
  '';

  meta = with lib; {
    description = "7-Zip 24.09 SDK (library) for the KrKr2 emulator";
    homepage = "https://www.7-zip.org";
    license = licenses.lgpl2Plus;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
