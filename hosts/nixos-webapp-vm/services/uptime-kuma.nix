{
  config,
  lib,
  pkgs,
  ...
}: let
  # Uptime Kuma's Vue app has no native subpath support: vue-router uses
  # history base "/" and a few pages do raw location.href="/...". Since
  # nginx exposes it under /status/, patch a copy of the already-built
  # frontend so the router base and raw navigations live under /status/.
  # API/asset paths stay root-absolute on purpose; nginx proxies those
  # prefixes to Kuma as well.
  uptimeKumaDist =
    pkgs.runCommand "uptime-kuma-status-dist" {
      nativeBuildInputs = [pkgs.gzip];
    } ''
      cp -r ${pkgs.uptime-kuma}/lib/node_modules/uptime-kuma/dist "$out"
      chmod -R u+w "$out"

      js=$(ls "$out/assets/index-"*.js)
      if [ "$(echo "$js" | wc -l)" != "1" ]; then
        echo "uptime-kuma-status-path: expected exactly one main bundle, got: $js" >&2
        exit 1
      fi

      for pattern in \
        'history:xne()' \
        'location.href="/page-not-found"' \
        'location.href="/manage-status-page"' \
        'location.href="/status/"' \
        'location.href="/setup"'; do
        if ! grep -q "$pattern" "$js"; then
          echo "uptime-kuma-status-path: pattern not found in bundle: $pattern" >&2
          exit 1
        fi
      done

      sed -i 's/history:xne()/history:xne("\/status\/")/' "$js"
      sed -i 's#location.href="/page-not-found"#location.href="/status/page-not-found"#' "$js"
      sed -i 's#location.href="/manage-status-page"#location.href="/status/manage-status-page"#' "$js"
      # Kuma's own public status pages live at /status/<slug> upstream;
      # under our reverse-proxy prefix that is /status/status/<slug>.
      sed -i 's#location.href="/status/"#location.href="/status/status/"#g' "$js"
      sed -i 's#location.href="/setup"#location.href="/status/setup"#' "$js"

      # Publish the patched bundle under a new name so clients that cached
      # the old bundle are forced to refetch it.
      oldname=$(basename "$js")
      newname="''${oldname%.js}-status.js"
      newjs="$out/assets/$newname"
      mv "$js" "$newjs"
      rm -f "$out/assets/$oldname".gz "$out/assets/$oldname".br
      gzip -9 -n -c "$newjs" > "$newjs.gz"

      sed -i "s#$oldname#$newname#g" "$out/index.html"
      rm -f "$out/index.html.gz" "$out/index.html.br"
    '';

  uptimeKuma = pkgs.runCommand "uptime-kuma-status-path" {} ''
    cp -a ${pkgs.uptime-kuma}/. "$out/"
    chmod -R u+w "$out/lib/node_modules/uptime-kuma"
    rm -rf "$out/lib/node_modules/uptime-kuma/dist"
    cp -r ${uptimeKumaDist} "$out/lib/node_modules/uptime-kuma/dist"
  '';
in {
  # Uptime Kuma listens only on 127.0.0.1:3001; nginx on this host exposes it
  # at :18080/status/ (HTTP) and :18081/status/ (HTTPS).
  services.uptime-kuma = {
    enable = true;
    package = uptimeKuma;
  };
}
