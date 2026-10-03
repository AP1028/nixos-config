{ lib, stdenv, fetchurl, cmake }:
stdenv.mkDerivation rec {
  pname = "uchardet";
  version = "0.0.8";
  src = fetchurl {
    url = "https://www.freedesktop.org/software/uchardet/releases/uchardet-${version}.tar.xz";
    hash = "sha256-6Xpgz8AKHBR6Z0sJe7FCKr2fp4otnOPz/cwueKNKxfA=";
  };
  nativeBuildInputs = [ cmake ];
  cmakeFlags = [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
  meta = with lib; {
    description = "Universal charset detector";
    license = licenses.mpl20;
  };
}
