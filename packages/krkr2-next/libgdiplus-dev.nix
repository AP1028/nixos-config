{ lib, stdenv, symlinkJoin, libgdiplus }:
let
  headers = stdenv.mkDerivation {
    pname = "libgdiplus-headers";
    version = libgdiplus.version;
    src = libgdiplus.src;
    dontBuild = true;
    dontConfigure = true;
    installPhase = ''
      mkdir -p $out/include/libgdiplus
      cp src/*.h $out/include/libgdiplus/
    '';
  };
in symlinkJoin {
  name = "libgdiplus-with-headers-${libgdiplus.version}";
  paths = [ libgdiplus headers ];
  postBuild = ''
    # rewrite the pkg-config file to point at our merged include dir
    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/libgdiplus.pc <<'EOF'
prefix=$out
libdir=$out/lib
includedir=$out/include

Name: libgdiplus
Description: An Open Source implementation of the GDI+ API (with private headers)
Version: ${libgdiplus.version}
Libs: -L''${libdir} -lgdiplus
Cflags: -I''${includedir}/libgdiplus
EOF
    sed -i "s|\$out|$out|g" $out/lib/pkgconfig/libgdiplus.pc
  '';
}
