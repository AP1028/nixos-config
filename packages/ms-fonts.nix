{
  lib,
  stdenv,
  unzip,
}: let
  absoluteFontZip = /etc/nixos/git-excluded/fonts/ms-fonts.zip;
  fileExists = builtins.pathExists absoluteFontZip;
in
  stdenv.mkDerivation {
    pname = "ms-fonts";
    version = "1.0";

    # Bypasses Flake isolation safely
    src =
      if fileExists
      then absoluteFontZip
      else null;

    nativeBuildInputs = [unzip];

    # If the file doesn't exist, skip the build phases entirely
    # so the flake never crashes.
    unpackPhase =
      if fileExists
      then "unzip $src"
      else "mkdir empty_dir; cd empty_dir";

    installPhase =
      if fileExists
      then ''
        mkdir -p $out/share/fonts/truetype
        find . -name '*.ttf' -exec cp {} $out/share/fonts/truetype/ \;
        find . -name '*.ttc' -exec cp {} $out/share/fonts/truetype/ \;
      ''
      else ''
        mkdir -p $out/share/fonts/truetype
      '';

    meta = with lib; {
      description = "Microsoft Chinese Core Fonts (SimSun, YaHei, etc.) extracted from Windows";
      platforms = platforms.all;
    };
  }
