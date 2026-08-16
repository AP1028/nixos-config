{
  config,
  lib,
  pkgs,
  ...
}: let
  # Uptime Kuma's Vue app has no native subpath support: vue-router uses
  # history base "/" and a few pages do raw location.href="/...". nginx
  # exposes it under /monitor/, so patch a copy of the already-built frontend
  # so the router base and raw navigations live under /monitor/. API/asset
  # paths stay root-absolute on purpose; nginx proxies those prefixes to
  # Kuma as well.
  uptimeKumaDist =
    pkgs.runCommand "uptime-kuma-monitor-dist" {
      nativeBuildInputs = [pkgs.gzip];
    } ''
      cp -r ${pkgs.uptime-kuma}/lib/node_modules/uptime-kuma/dist "$out"
      chmod -R u+w "$out"

      js=$(ls "$out/assets/index-"*.js)
      if [ "$(echo "$js" | wc -l)" != "1" ]; then
        echo "uptime-kuma-monitor: expected exactly one main bundle, got: $js" >&2
        exit 1
      fi

      for pattern in \
        'history:xne()' \
        'location.href="/page-not-found"' \
        'location.href="/manage-status-page"' \
        'location.href="/status/"' \
        'location.href="/setup"' \
        'location.pathname==="/setup-database"'; do
        if ! grep -q "$pattern" "$js"; then
          echo "uptime-kuma-monitor: pattern not found in bundle: $pattern" >&2
          exit 1
        fi
      done

      sed -i 's/history:xne()/history:xne("\/monitor\/")/' "$js"
      sed -i 's#location.href="/page-not-found"#location.href="/monitor/page-not-found"#' "$js"
      sed -i 's#location.href="/manage-status-page"#location.href="/monitor/manage-status-page"#' "$js"
      # Kuma's public status pages live at /status/<slug> upstream; under the
      # /monitor/ reverse-proxy prefix that is /monitor/status/<slug>.
      sed -i 's#location.href="/status/"#location.href="/monitor/status/"#g' "$js"
      sed -i 's#location.href="/setup"#location.href="/monitor/setup"#' "$js"

      # Kuma disables socket.io on /^\/status/ because upstream that path is
      # only its public status page. Under our /monitor/ proxy, socket.io must
      # stay enabled for /monitor/dashboard and /monitor/setup, and only be
      # disabled for the public status paths /monitor/status/...
      if ! grep -qF '/^\/status/,/^\/$/]' "$js"; then
        echo "uptime-kuma-monitor: no-socket regex pattern not found in bundle" >&2
        exit 1
      fi
      sed -i 's#,/^\\/status/,/^\\/$/]#,/^\\/monitor\\/status/,/^\\/$/]#' "$js"
      if ! grep -qF '/^\/monitor\/status/,/^\/$/]' "$js"; then
        echo "uptime-kuma-monitor: narrowed no-socket regex was not applied" >&2
        exit 1
      fi
      sed -i 's#location.pathname==="/setup-database"#location.pathname==="/monitor/setup-database"#' "$js"

      # Publish the patched bundle under a new name so clients that cached
      # the old bundle are forced to refetch it.
      oldname=$(basename "$js")
      newname="''${oldname%.js}-monitor.js"
      newjs="$out/assets/$newname"
      mv "$js" "$newjs"
      rm -f "$out/assets/$oldname".gz "$out/assets/$oldname".br
      gzip -9 -n -c "$newjs" > "$newjs.gz"

      sed -i "s#$oldname#$newname#g" "$out/index.html"
      rm -f "$out/index.html.gz" "$out/index.html.br"
    '';

  uptimeKuma = pkgs.runCommand "uptime-kuma-monitor-path" {} ''
    cp -a ${pkgs.uptime-kuma}/. "$out/"
    # The copied wrapper script still hardcodes the original store path; point
    # it at this patched copy so the patched dist/ is the one that runs.
    chmod -R u+w "$out/bin"
    sed -i "s#${pkgs.uptime-kuma}#$out#g" "$out/bin/uptime-kuma-server"
    chmod -R u+w "$out/lib/node_modules/uptime-kuma"
    rm -rf "$out/lib/node_modules/uptime-kuma/dist"
    cp -r ${uptimeKumaDist} "$out/lib/node_modules/uptime-kuma/dist"
  '';
in {
  # Uptime Kuma listens only on 127.0.0.1:3001; nginx on this host exposes
  # the admin UI at /monitor/... and Kuma's public status pages at
  # /monitor/status/<slug> on both HTTP 18080 and HTTPS 18081.
  services.uptime-kuma = {
    enable = true;
    package = uptimeKuma;
  };
}
