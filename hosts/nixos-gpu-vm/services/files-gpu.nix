# Web file UI for tianyixia's GPU VM storage pool.
#
# One FileBrowser Quantum instance exposes a single read+write source:
#
#   /home/tianyixia/files-gpu -> READ+WRITE (drag & drop upload, mkdir, rename)
#
# NO DELETE ANYWHERE: the only web user has Permissions.Delete = false.
#
# Why FileBrowser Quantum? Its upstream web UI already provides the requested
# Google-Drive-like UX: list/grid views, ctrl/shift multi-select, batch
# download, on-the-fly .zip of folders, and drag & drop uploads. `viewable:
# true` source rules disable its background indexer, so the pool is listed
# on demand instead of being scanned at boot.
#
# Self-contained twin of hosts/nixos-file-vm/services/file-web.nix (the NAS
# UI): same app, same auth policy, same nginx architecture. It is served at
# /files/files-gpu/ — the webapp VM nests this twin under the /files/
# namespace next to the file-vm UI (/files/Public, /files/Dropbox) — and the
# service runs as tianyixia itself: the pool is the user's own home
# directory, so ownership stays clean (every file the web UI creates belongs
# to the same account that uses the pool from the shell). Same trust
# boundary as vllm-manager on this host, which also runs as tianyixia. The
# pool is a plain directory on the VM disk (no ZFS).
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Quantum's vue-router uses `baseURL` for BOTH history and API paths, and
  # its file-listing ROUTE is hardcoded "/files/:path" in the bundle. For
  # this instance the UI is published under /files/files-gpu/ (the webapp
  # hosts the file-vm UI at /files/ and this twin at /files/files-gpu/), so
  # the preBuild patch rewrites:
  #   * history base      Nt.baseURL  -> "/"           (browser URLs keep ONE
  #                                                     /files/files-gpu/ prefix)
  #   * item hrefs        `${baseURL}files/` -> `/files/files-gpu/`
  #   * router routes     "/files/", "/files" -> "/files/files-gpu/" variants
  # API/static traffic keeps using Nt.baseURL (= /files/files-gpu/).
  filebrowserQuantum = pkgs.filebrowser-quantum.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.gzip];
    # TestJSONAuth_NoTimingAttack measures ms-level auth latencies with only
    # 5 samples and t.Errorfs on any user deviating >30% from the overall
    # mean. On a loaded VM (vLLM shares this host) that outlier check flakes
    # (observed: admin deviating 50%), while the actual timing-attack
    # assertion — valid vs invalid users, 20% threshold — passed in the
    # failing logs. Skip just this statistical test; everything else runs.
    checkFlags = (old.checkFlags or []) ++ ["-skip=TestJSONAuth_NoTimingAttack"];
    preBuild =
      (old.preBuild or "")
      + ''
        chmod -R u+w http/embed
        for f in http/embed/assets/index-*.js.gz; do
          plain="''${f%.gz}"
          zcat "$f" > "$plain"

          if ! grep -q 'history:RK(Nt.baseURL)' "$plain"; then
            echo "files-gpu: quantum router history pattern not found; update the patch" >&2
            exit 1
          fi
          if ! grep -q '`''${Nt.baseURL}files/' "$plain"; then
            echo "files-gpu: quantum item-href pattern not found; update the patch" >&2
            exit 1
          fi
          if ! grep -q '"/files/"' "$plain"; then
            echo "files-gpu: quantum router route pattern not found; update the patch" >&2
            exit 1
          fi
          if ! grep -q '`''${window.location.origin}''${Nt.baseURL}''${o.startsWith("/")?o.slice(1):o}`' "$plain"; then
            echo "files-gpu: quantum new-tab pattern not found; update the patch" >&2
            exit 1
          fi

          # vue-router history base: browser URLs are /files/files-gpu/Public,
          # not /files/files-gpu//files/files-gpu/Public. API/static keep
          # using Nt.baseURL (/files/files-gpu/).
          sed -i 's/history:RK(Nt.baseURL)/history:RK("\/")/' "$plain"

          # Route NAVIGATIONS are backtick template literals (e.g.
          # /files/{source}) that the quoted-string seds below cannot
          # match: the source auto-redirect, breadcrumbs and recent-links
          # all push /files/... URLs. Without this, the auto-redirect
          # pushes the route root again and the SPA never issues the
          # listing request. MUST run before the item-href sed, which
          # itself emits /files/files-gpu/.
          #
          # NOTE: sed patterns use \x60 (hex backtick) because an escaped
          # `\`` is NOT matched by GNU sed (it keeps the backslash), so the
          # classic \`-escaped seds silently no-op.
          sed -i 's#\x60/files/#\x60/files/files-gpu/#g' "$plain"

          # Folder item hrefs: one /files/files-gpu/ prefix.
          sed -i 's#\x60''${Nt.baseURL}files/#\x60/files/files-gpu/#g' "$plain"

          # The file-listing ROUTE is hardcoded "/files/:path" upstream. The
          # file-vm instance relies on that (served at /files/); this twin is
          # served at /files/files-gpu/, so point the route there too — with
          # the wrong route the SPA falls into its catch-all and redirects
          # to bogus /files/... URLs ("nothing to show here").
          sed -i 's#"/files/"#"/files/files-gpu/"#g' "$plain"
          sed -i 's#"/files"#"/files/files-gpu"#g' "$plain"

          # "Open in new tab": fullPath already carries /files/files-gpu/.
          sed -i 's#\x60''${window.location.origin}''${Nt.baseURL}''${o.startsWith("/")?o.slice(1):o}\x60#\x60''${window.location.origin}''${o}\x60#g' "$plain"

          gzip -9 -n -c "$plain" > "$f.new"
          mv "$f.new" "$f"
          rm -f "$plain"
        done

        # The upstream bundle name is content-hashed, but our patch changes
        # the content without changing the name. Browsers cache the asset for
        # 24h, so publish the patched bundle under a new name and point the
        # SPA template at it.
        if ! grep -q 'index-RkHXvfmg.js' http/embed/public/index.html; then
          echo "files-gpu: quantum index template asset pattern not found; update the patch" >&2
          exit 1
        fi
        mv http/embed/assets/index-RkHXvfmg.js.gz http/embed/assets/index-RkHXvfmg-files-gpu4-patched.js.gz
        sed -i 's/index-RkHXvfmg\.js/index-RkHXvfmg-files-gpu4-patched.js/g' http/embed/public/index.html
      '';
  });

  # Folder sizes cannot be computed without the background indexer, and
  # indexing the pool at boot is exactly what we avoid. With the
  # "viewable only" (on-demand listing) mode the app would otherwise show a
  # meaningless "4.0 KB" for every folder, so the UI hides folder sizes and
  # the API reports them as 0 (useLogicalSize).
  fileWebCustomCss = pkgs.writeText "files-gpu-custom.css" ''
    /* Folder sizes are disabled: on-demand listing has no recursive size
       index, and a fake 4 KB per folder is worse than no size at all. */
    .listing-item[data-dir="true"] > .text > .size {
      display: none !important;
    }
  '';

  # Shared proxy settings for every /files/files-gpu/... nginx location.
  fileWebProxyExtraConfig = ''
    # NAS traffic: multi-GB files and long .zip streams are normal. Timeouts
    # are 7 days between successive I/O ops (= effectively unlimited for
    # multi-hundred-GB downloads). NOTE: 0 (nginx "no timeout") is NOT used
    # here — this nginx version reports an instant upstream timeout for the
    # first request when proxy_read_timeout/proxy_send_timeout are 0.
    client_max_body_size 0;
    client_body_timeout 604800s;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 604800s;
    proxy_send_timeout 604800s;
    send_timeout 604800s;

    # Trust boundary for quantum's proxy auth (must override inbound).
    # Host / X-Real-IP / X-Forwarded-* come from recommendedProxySettings;
    # re-setting Host here would send it to the backend twice and Go's HTTP
    # parser rejects duplicate Host.
    proxy_set_header X-Remote-User "files";
  '';

  fileWebConfig = (pkgs.formats.yaml {}).generate "files-gpu.yaml" {
    server = {
      port = 8081;
      listen = "127.0.0.1"; # only nginx is public; nginx is what injects auth
      # The UI is published under /files/files-gpu/ (both directly on this
      # VM and via the nixos-webapp-vm WAN proxy, which nests it under the
      # /files/ namespace next to the file-vm UI), so all frontend/api URLs
      # carry it.
      baseURL = "/files/files-gpu/";
      disableUpdateCheck = true;
      logging = [
        {levels = "info|warning|error";}
      ];
      database = "/var/lib/fileweb/database.db";
      cacheDir = "/var/cache/fileweb";
      cacheDirCleanup = false;
      disableWebDAV = true; # web UI only; no second write surface to police
      maxArchiveSize = 0; # 0 = no limit on folder .zip downloads
      filesystem = {
        createFilePermission = "644";
        createDirectoryPermission = "755";
      };
      sources = [
        {
          path = "/home/tianyixia/files-gpu";
          name = "files-gpu";
          config = {
            readOnly = false;
            private = true;
            defaultEnabled = true;
            defaultUserScope = "/";
            useLogicalSize = true; # folders report 0 instead of fake 4 KB
            rules = [
              {
                folderPath = "/";
                viewable = true; # list on demand, never background-index
              }
            ];
          };
        }
      ];
    };

    # Trusted-header auth: only nginx can reach 127.0.0.1:8081 and it
    # hard-codes X-Remote-User. The first request auto-provisions user
    # "files" from the userDefaults below (non-admin, delete = false).
    auth = {
      tokenExpirationHours = 168;
      adminUsername = "admin"; # intentionally NOT the proxy identity
      methods = {
        password = {
          enabled = false;
          signup = false;
        };
        noauth = false;
        proxy = {
          enabled = true;
          header = "X-Remote-User";
        };
      };
    };

    frontend = {
      name = "GPU Files";
      description = "Web file browser for tianyixia's files-gpu pool";
      disableDefaultLinks = true;
      styling = {
        customCSS = "${fileWebCustomCss}"; # hide folder size captions
      };
    };

    userDefaults = {
      sidebar = {
        sticky = true;
        showTools = false; # indexer is off, so search/duplicate tools are moot
      };
      listing = {
        viewMode = "normal"; # normal | list | grid | compact
        showSelectMultiple = true; # visible multi-select control on desktop
        quickDownload = true;
        deleteAfterArchive = false; # even archive/extract must never unlink
        dateFormat = false;
        showHidden = false;
      };
      ui = {
        darkMode = true;
        themeColor = "var(--blue)";
        locale = "en";
      };
      account = {
        permissions = {
          api = false;
          admin = false;
          modify = true; # the pool needs rename / overwrite / copy
          share = false;
          realtime = false;
          delete = false; # NO DELETE ANYWHERE
          create = true; # the pool needs upload / mkdir
          download = true; # download everything
        };
        lockPassword = true;
        disableSettings = true;
      };
    };
  };
in {
  # The service runs as tianyixia (vllm-manager precedent on this host): the
  # pool is the user's own home directory, so file ownership always matches
  # the account that uses the pool. The backend still binds 127.0.0.1 and
  # nginx is the only public listener, so tianyixia's account is only ever
  # reachable through the FileBrowser app itself.
  systemd.services.fileweb = {
    description = "GPU VM web file UI (FileBrowser Quantum)";
    after = ["local-fs.target" "network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      User = "tianyixia";
      Group = "users";
      ExecStart = "${lib.getExe filebrowserQuantum} -c ${fileWebConfig}";
      WorkingDirectory = "/var/lib/fileweb"; # bolt DB + sqlite index live here
      StateDirectory = "fileweb";
      StateDirectoryMode = "0750";
      CacheDirectory = "fileweb";
      CacheDirectoryMode = "0750";
      UMask = "0002";
      Restart = "on-failure";
      RestartSec = 3;

      # Hardening. Only the configured source is reachable; the rest of the
      # system stays read-only. ProtectHome stays off because the pool lives
      # inside /home/tianyixia and the service runs as its owner.
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = false;
      ReadWritePaths = [
        "/home/tianyixia/files-gpu"
        "/var/lib/fileweb"
        "/var/cache/fileweb"
      ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = "";
    };
  };

  # nginx is the only public listener and the trust boundary for auth: it
  # overwrites any client-supplied X-Remote-User with the single anonymous
  # "files" identity before proxying to the localhost-only backend.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    # Silence the "could not build optimal proxy_headers_hash startup warning"
    # (recommendedProxySettings + our X-Remote-User header exceed the default
    # hash table).
    appendHttpConfig = "proxy_headers_hash_max_size 512;";
    virtualHosts.files-gpu = {
      serverName = "_";
      listen = [
        {
          addr = "0.0.0.0";
          port = 8080;
        }
      ];
      locations = {
        # Direct bookmarks to the root keep working.
        "= /" = {
          return = "308 /files/files-gpu/";
        };

        # Redirect the old /files-gpu/ (and even older /file-gpu/) locations
        # to the new /files/files-gpu/ home.
        "= /file-gpu" = {
          return = "308 /files/files-gpu/";
        };
        "= /file-gpu/" = {
          return = "308 /files/files-gpu/";
        };
        "= /files-gpu" = {
          return = "308 /files/files-gpu/";
        };
        "= /files-gpu/" = {
          return = "308 /files/files-gpu/";
        };

        # API / static traffic stays on its Quantum baseURL
        # (/files/files-gpu/...).
        "/files/files-gpu/api/" = {
          proxyPass = "http://127.0.0.1:8081";
          proxyWebsockets = true;
          extraConfig = fileWebProxyExtraConfig;
        };
        "/files/files-gpu/public/" = {
          proxyPass = "http://127.0.0.1:8081";
          proxyWebsockets = true;
          extraConfig = fileWebProxyExtraConfig;
        };
        "= /files/files-gpu/health" = {
          proxyPass = "http://127.0.0.1:8081";
          extraConfig = fileWebProxyExtraConfig;
        };

        # Everything else under /files/files-gpu/ is a vue-router deep link
        # (/files/files-gpu/files-gpu/...); serve the SPA index for it. The
        # patched router uses history base "/" and route /files/files-gpu/,
        # so browser URLs never become /files/files-gpu//files/files-gpu/...
        "/files/files-gpu/" = {
          proxyPass = "http://127.0.0.1:8081";
          proxyWebsockets = true;
          extraConfig =
            ''
              rewrite ^/files/files-gpu/.*$ /files/files-gpu/ break;
            ''
            + fileWebProxyExtraConfig;
        };
      };
    };
  };

  # The storage pool itself: a plain directory on the VM disk (no ZFS on
  # this host), created at boot as the user's own writable space. Named
  # "files-gpu" to match the UI source and URL prefix.
  systemd.tmpfiles.rules = [
    "d /home/tianyixia/files-gpu 0770 tianyixia users -"
  ];

  # firewall-open.nix already opens every port on this VM; no extra firewall
  # rule is required. Kept out of the vllm/comfyui modules so this new
  # service stays completely self-contained.

  # nginx proxies to fileweb on first use; ordering avoids a transient 502 on
  # boot while the backend (and its bolt DB) comes up.
  systemd.services.nginx = {
    after = lib.mkAfter ["fileweb.service"];
    wants = lib.mkAfter ["fileweb.service"];
  };
}
