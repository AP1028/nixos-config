{pkgs, ...}: let
  wps-wrapped = pkgs.symlinkJoin {
    name = "wpsoffice-cn-zh";
    paths = [pkgs.wpsoffice-cn];
    buildInputs = [pkgs.makeWrapper];
    postBuild = ''
      for bin in $out/bin/*; do
        wrapProgram "$bin" \
          --set LANG zh_CN.UTF-8 \
          --set LC_ALL zh_CN.UTF-8
      done

      rm $out/share/applications/*.desktop
      cp ${pkgs.wpsoffice-cn}/share/applications/*.desktop $out/share/applications/
      chmod +w $out/share/applications/*.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wps %f|" $out/share/applications/wps-office-wps.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/et %f|" $out/share/applications/wps-office-et.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wpp %f|" $out/share/applications/wps-office-wpp.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wpspdf %f|" $out/share/applications/wps-office-pdf.desktop

      find $out -name wpscloudsvr \( -type f -o -type l \) -print0 2>/dev/null | while IFS= read -r -d "" svr; do
        rm -f "$svr"
        printf '#!/bin/sh\nexit 0\n' > "$svr"
        chmod +x "$svr"
      done
    '';
  };
in {
  environment.systemPackages = [wps-wrapped];
}
