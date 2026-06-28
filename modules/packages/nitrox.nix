{pkgs, ...}: let
  nitrox = pkgs.stdenv.mkDerivation rec {
    pname = "nitrox-bin";
    version = "1.8.1.0";

    src = pkgs.fetchzip {
      url = "https://github.com/SubnauticaNitrox/Nitrox/releases/download/${version}/Nitrox_${version}_linux_x64.zip";
      hash = "sha256-TQEZjFVKRaQPRshJk6j18hLG9mihLOVrd8ZpzhJtRF0=";
      stripRoot = false;
    };

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
    ];

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.fontconfig
      pkgs.libX11
      pkgs.libICE
      pkgs.libSM
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/src/
      cp -r $src/* $out/src/

      mkdir -p $out/bin
      cp ${./nitrox-launcher.sh} $out/bin/Nitrox.Launcher
      substituteInPlace $out/bin/Nitrox.Launcher \
        --replace '@nitroxSrc@' "$out/src" \
        --replace '@dotnetRoot@' "${pkgs.dotnet-sdk_9}/share/dotnet" \
        --replace '@rsync@' "${pkgs.rsync}/bin/rsync"
      chmod +x $out/bin/Nitrox.Launcher

      makeWrapper $out/src/Nitrox.Server.Subnautica $out/bin/Nitrox.Server.Subnautica \
        --set DOTNET_ROOT ${pkgs.dotnet-sdk_9}/share/dotnet

      runHook postInstall
    '';

    meta = with pkgs.lib; {
      homepage = "https://nitrox.rux.gg/";
      description = "Multiplayer Mod for Subnautica";
      license = licenses.gpl3Only;
      platforms = platforms.linux;
      mainProgram = "Nitrox.Launcher";
    };
  };
in {
  environment.systemPackages = [nitrox];
}
