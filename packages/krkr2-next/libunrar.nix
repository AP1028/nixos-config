{ lib, stdenv, fetchurl }:
stdenv.mkDerivation rec {
  pname = "libunrar";
  version = "7.1.6";
  src = fetchurl {
    url = "https://www.rarlab.com/rar/unrarsrc-${version}.tar.gz";
    hash = "sha256-yl4do33W+ht4u17WdUhkE/eeSpF3CXRKoEtvk9/ZFPA=";
  };
  sourceRoot = "unrar";
  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES -f makefile lib CXXFLAGS="$CXXFLAGS -fPIC"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libunrar.so $out/lib/libunrar.so
    install -dm755 $out/include/unrar
    cp *.hpp $out/include/unrar/
    runHook postInstall
  '';
  # builds without a make install target; disable strip issues
  dontFixup = true;
  meta = with lib; {
    description = "UnRAR library (RAR extraction)";
    # RAR license (freeware, redistribution allowed)
    license = licenses.unfreeRedistributable;
  };
}
