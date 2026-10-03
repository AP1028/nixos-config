{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
}:

# Kirikiri SDL2 (a port of Kirikiri Z that runs on SDL2 platforms).
#
# Upstream ships no tagged releases with binaries; the "latest" prerelease is
# rebuilt by CI, so this pins the currently published Linux asset by hash. If
# upstream rebuilds it, the hash below has to be refreshed (or switch to a
# source build pinned at a commit).
let
  assets = {
    x86_64-linux = {
      url = "https://github.com/krkrsdl2/krkrsdl2/releases/download/latest/krkrsdl2-ubuntu.zip";
      hash = "sha256-ZvHl5xTWEoZUtQIeE9/BOyOpMk7qO6BGOV0M2Emn1so=";
    };
    aarch64-linux = {
      url = "https://github.com/krkrsdl2/krkrsdl2/releases/download/latest/krkrsdl2-ubuntu-arm64.zip";
      hash = "sha256-Kp/CCaT+j8qohjITk/sIkjUXV3Dk6FPStHa0KekL3xc=";
    };
  };
  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "krkrsdl2: no prebuilt asset for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "krkrsdl2";
  version = "unstable-2026-08-31";

  src = fetchurl {
    inherit (asset) url hash;
  };

  # The archive contains a single file at its root, so there is no directory
  # for the unpacker to switch into.
  sourceRoot = ".";

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
  ];

  # The upstream build statically links SDL2, FAudio, zlib, freetype, libpng
  # and opus; only the C++ runtime is dynamic.
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 krkrsdl2 $out/bin/krkrsdl2
    runHook postInstall
  '';

  meta = with lib; {
    description = "Kirikiri SDL2: SDL2 port of the Kirikiri Z visual novel engine";
    homepage = "https://krkrsdl2.github.io/krkrsdl2/en/";
    license = licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "krkrsdl2";
  };
})
