{
  lib,
  stdenv,
  unzip,
}:
stdenv.mkDerivation {
  pname = "ms-fonts";
  version = "1.0";

  # Reference the local uncommitted zip file relatively
  # Adjust the dots here to point to your git-excluded directory from this file's location
  src = ../../git-excluded/fonts/ms-fonts.zip;

  nativeBuildInputs = [unzip];

  unpackPhase = ''
    unzip $src
  '';

  installPhase = ''
    mkdir -p $out/share/fonts/truetype

    # Safely find and copy all .ttf and .ttc files from the root of the zip
    find . -name '*.ttf' -exec cp {} $out/share/fonts/truetype/ \;
    find . -name '*.ttc' -exec cp {} $out/share/fonts/truetype/ \;
  '';

  meta = with lib; {
    description = "Microsoft Chinese Core Fonts (SimSun, YaHei, etc.) extracted from Windows";
    platforms = platforms.all;
  };
}
