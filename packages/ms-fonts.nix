{
  lib,
  stdenv,
  unzip,
}: let
  # Define the absolute path on your filesystem where the zip lives
  absoluteFontZip = /etc/nixos/git-excluded/fonts/ms-fonts.zip;
in
  stdenv.mkDerivation {
    pname = "ms-fonts";
    version = "1.0";

    # Pure-mode friendly guard: if the absolute path exists on the host, use it.
    # Otherwise, fall back to an empty string to prevent evaluation crashes.
    src =
      if builtins.pathExists absoluteFontZip
      then absoluteFontZip
      else "";

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
