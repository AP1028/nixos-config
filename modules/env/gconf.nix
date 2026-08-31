{ lib, stdenv, fetchurl, pkg-config, dbus-glib, glib, libxml2, polkit, python3, intltool, gtk2 }:

stdenv.mkDerivation rec {
  pname = "gconf";
  version = "3.2.6";

  src = fetchurl {
    url = "mirror://gnome/sources/GConf/3.2/GConf-${version}.tar.xz";
    sha256 = "sha256-GRK5GAOrCaXu0002S/Cf46KpyWdR/eA6Tgz6UaBNeEw=";
  };

  outputs = [ "out" "dev" "man" ];

  buildInputs = [ libxml2 python3 gtk2 polkit ];
  propagatedBuildInputs = [ glib dbus-glib ];
  nativeBuildInputs = [ pkg-config intltool ];

  configureFlags = [ "--disable-orbit" ];

  meta = with lib; {
    homepage = "https://projects.gnome.org/gconf/";
    description = "Deprecated system for storing application preferences";
    platforms = platforms.linux;
  };
}
