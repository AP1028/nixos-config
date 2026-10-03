{
  lib,
  flutter347,
  fetchFromGitHub,
  engine,
  cmake,
  ninja,
  gtk3,
}:

flutter347.buildFlutterApplication {
  pname = "krkr2-next";
  version = "1.5.0-unstable";

  src = fetchFromGitHub {
    owner = "reAAAq";
    repo = "KrKr2-Next";
    rev = "1abd1ed4e8aec7abd5d2524c3a9ad7886880602f";
    hash = "sha256-y5BFtHoTmlJh8qV1Jj87/WPiFadfKmkIIreeFlC9aiI=";
  };

  # The Flutter app lives in a subdirectory; the engine bridge plugin is a
  # relative path dependency (../../bridge/flutter_engine_bridge) that must
  # stay inside the unpacked source tree.
  sourceRoot = "source/apps/flutter_app";

  dontUseCmakeConfigure = true;

  pubspecLock = builtins.fromJSON (builtins.readFile ./pubspec.lock.json);

  nativeBuildInputs = [
    cmake
    ninja
  ];

  buildInputs = [
    gtk3
  ];

  postInstall = ''
    # Bundle the native engine (FFI) library next to the app binary; the
    # Flutter runner's rpath contains $ORIGIN/lib and the Dart FFI loader
    # looks for libengine_api.so.
    mkdir -p $out/app/krkr2-next/lib
    cp ${engine}/lib/libengine_api.so $out/app/krkr2-next/lib/
  '';

  meta = with lib; {
    description = "KrKr2-Next: cross-platform KiriKiri2 visual novel emulator built on Flutter";
    homepage = "https://github.com/reAAAq/KrKr2-Next";
    license = with licenses; [ mit ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "flutter_app";
  };
}
