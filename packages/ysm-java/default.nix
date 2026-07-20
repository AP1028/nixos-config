{ lib, stdenv, fetchurl, gcc, glibc, writeShellScriptBin, patchelf, pkgs }:

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
      if ! [ -x "$out/bin/java" ]; then
        echo "ERROR: java binary not found" >&2; exit 1
      fi
    '';
  };

  ysmFixLib = stdenv.mkDerivation {
    name = "libysm-fix";
    src = ./ysm-fix.c;
    dontUnpack = true;
    nativeBuildInputs = [ gcc ];
    buildPhase = ''
      JNI_H=$(find ${temurinJre} -name "jni.h" -path "*/include/jni.h" 2>/dev/null | head -1)
      if [ -z "$JNI_H" ]; then
        JNI_H=$(find ${pkgs.jdk21} -name "jni.h" -path "*/include/jni.h" 2>/dev/null | head -1)
      fi
      [ -n "$JNI_H" ] || { echo "jni.h not found" >&2; exit 1; }
      JNI_INC="$(dirname "$JNI_H")"
      JNI_MD_INC="$JNI_INC/linux"
      gcc -shared -fPIC -o libysm-fix.so $src \
        -I"$JNI_INC" -I"$JNI_MD_INC" -ldl -Os -s
    '';
    installPhase = ''
      mkdir -p $out/lib
      cp libysm-fix.so $out/lib/
    '';
  };

  ysmJavaWrapper = writeShellScriptBin "ysm-java" ''
    TEMURIN_JRE="${temurinJre}"
    YSM_LIB="${ysmFixLib}/lib/libysm-fix.so"
    GCC_LIB="${stdenv.cc.cc.lib}/lib"
    export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$GCC_LIB"
    export LD_PRELOAD="$YSM_LIB"
    exec "$TEMURIN_JRE/bin/java" "$@"
  '';

in stdenv.mkDerivation {
  name = "ysm-java";
  buildInputs = [ temurinJre ysmFixLib ysmJavaWrapper ];
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
    longDescription = ''
      Clean Temurin 21 JRE (no nixpkgs wrapper) + libysm-fix LD_PRELOAD
      that bypasses YSM native DRM (err:54 + err:56). Use 'ysm-java' instead
      of 'java' for Minecraft commands.
    '';
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
