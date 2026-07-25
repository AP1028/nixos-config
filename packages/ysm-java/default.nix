{ lib, stdenv, fetchurl, writeShellScriptBin, patchelf, pkgs, gtk3, glib, cairo, zenity, fontconfig }:

let
  temurinJre = stdenv.mkDerivation {
    name = "temurin-jre-21.0.11";
    src = fetchurl {
      url = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.11%2B10/OpenJDK21U-jre_x64_linux_hotspot_21.0.11_10.tar.gz";
      hash = "sha256-5QOKrjyp/2cLxpZJawco29I9KAAmutMCkcuRkiHs/cs=";
    };
    nativeBuildInputs = [ patchelf ];
    installPhase = ''
      mkdir -p $out
      cp -r * $out/
      for f in $out/bin/*; do
        if [ -x "$f" ] && head -1 "$f" 2>/dev/null | grep -q "ELF"; then
          patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" "$f" 2>/dev/null || true
        fi
      done
      [ -x "$out/bin/java" ] || { echo "ERROR: java binary not found" >&2; exit 1; }
    '';
  };

  jniInc = "${temurinJre}/include";
  jniMdInc = "${jniInc}/linux";

  ysmFixLib = stdenv.mkDerivation {
    name = "libysm-fix";
    src = ./ysm-fix.c;
    dontUnpack = true;
    nativeBuildInputs = with pkgs; [ gcc ];
    buildPhase = ''
      JNI_INC="${jniInc}"
      JNI_MD_INC="${jniMdInc}"
      [ -d "$JNI_INC" ] || JNI_INC=$(find ${pkgs.jdk21} -name "jni.h" -path "*/include/jni.h" -exec dirname {} \; | head -1)
      [ -d "$JNI_MD_INC" ] || JNI_MD_INC="$JNI_INC/linux"
      gcc -shared -fPIC -o libysm-fix.so $src \
        -I"$JNI_INC" -I"$JNI_MD_INC" -ldl -lpthread -Os -s
    '';
    installPhase = ''
      mkdir -p $out/lib
      cp libysm-fix.so $out/lib/
    '';
  };

  ysmJavaWrapper = writeShellScriptBin "ysm-java" ''
    export PATH="${zenity}/bin''${PATH:+:$PATH}"
    export LD_LIBRARY_PATH="${stdenv.cc.cc.lib}/lib:${gtk3.out}/lib:${glib.out}/lib:${cairo.out}/lib:${fontconfig.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export FONTCONFIG_FILE="/etc/fonts/fonts.conf"
    export LD_PRELOAD="${ysmFixLib}/lib/libysm-fix.so"
    exec "${temurinJre}/bin/java" "$@"
  '';

in stdenv.mkDerivation {
  name = "ysm-java";
  buildInputs = [ temurinJre ysmFixLib ysmJavaWrapper gtk3 glib cairo ];
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/lib
    cp -r ${temurinJre}/* $out/
    cp ${ysmFixLib}/lib/libysm-fix.so $out/lib/
    cp ${ysmJavaWrapper}/bin/ysm-java $out/bin/ysm-java
    chmod +x $out/bin/ysm-java
  '';
  meta = {
    description = "Temurin 21 JRE + libysm-fix for YSM mod on NixOS";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
