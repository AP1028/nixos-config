{
  lib,
  stdenv,
  fetchurl,
  unar,
}:
stdenv.mkDerivation {
  pname = "harmonyos-sans-font";
  version = "1.0";

  # Download the RAR file
  src = fetchurl {
    url = "https://developer.huawei.com/Enexport/sites/default/images/download/next/HarmonyOS-Sans.rar";
    hash = "sha256-UQJ0+8EugKvmQdew2b1NK7T+wRG3txASI2Sncj/hK9c=";
  };

  # Bring in 'unar' to extract the RAR file
  nativeBuildInputs = [unar];

  # Extract the RAR file
  unpackPhase = ''
    # unar extracts the contents into the build directory
    unar $src
  '';

  # Install the fonts
  installPhase = ''
    # Create the target directories
    mkdir -p $out/share/fonts/truetype
    mkdir -p $out/share/fonts/opentype

    # Find any .ttf or .otf files in the extracted folder and copy them over
    find . -name '*.ttf' -exec cp {} $out/share/fonts/truetype/ \;
    find . -name '*.otf' -exec cp {} $out/share/fonts/opentype/ \;
  '';

  meta = with lib; {
    description = "HarmonyOS Sans Font";
    platforms = platforms.all;
  };
}
