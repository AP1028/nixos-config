# Web file UI for the HDD ZFS pool.
#
# One FileBrowser Quantum instance exposes exactly two of the three datasets:
#
#   /hdd/Public   -> READ ONLY  (download / zip / preview only)
#   /hdd/Dropbox  -> READ+WRITE (drag & drop upload, mkdir, rename)
#
# NO DELETE ANYWHERE: the only web user has Permissions.Delete = false, and
# Public is additionally protected by `source.config.readOnly`.
#
# ─────────────────────────────────────────────────────────────────────────────
# AUTH HOOK — /hdd/Private
#
# /hdd/Private is deliberately NOT listed in `server.sources` below, so the
# web UI never serves, lists, searches or touches it. If a password-protected
# Private section is added later, add a third source here
# (path = "/hdd/Private") and switch the `auth.methods` block from the current
# trusted `proxy` auth (nginx injects the identity) to `password` / `oidc` /
# JWT with an allow-list for that source. Nothing else needs to change.
# ─────────────────────────────────────────────────────────────────────────────
#
# Why FileBrowser Quantum? Its upstream web UI already provides the requested
# Google-Drive-like UX: list/grid views, ctrl/shift multi-select, batch
# download, on-the-fly .zip of folders, and drag & drop uploads. `viewable:
# true` source rules disable its background indexer, so the 543G Public tree
# is listed on demand instead of being scanned at boot.
{
  config,
  lib,
  pkgs,
  ...
}: let
  fileWebConfig = (pkgs.formats.yaml {}).generate "file-web.yaml" {
    server = {
      port = 8081;
      listen = "127.0.0.1"; # only nginx is public; nginx is what injects auth
      baseURL = "";
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
          path = "/hdd/Public";
          name = "Public";
          config = {
            readOnly = true; # hard guarantee: no upload/rename/mkdir/delete
            private = true;
            defaultEnabled = true;
            defaultUserScope = "/";
            rules = [
              {
                folderPath = "/";
                viewable = true; # list on demand, never background-index
              }
            ];
          };
        }
        {
          path = "/hdd/Dropbox";
          name = "Dropbox";
          config = {
            readOnly = false;
            private = true;
            defaultEnabled = true;
            defaultUserScope = "/";
            rules = [
              {
                folderPath = "/";
                viewable = true;
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
      name = "NAS Files";
      description = "Web file browser for the HDD ZFS pool";
      disableDefaultLinks = true;
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
          modify = true; # Dropbox needs rename / overwrite / copy
          share = false;
          realtime = false;
          delete = false; # NO DELETE ANYWHERE
          create = true; # Dropbox upload / mkdir
          download = true; # Public + Dropbox download
        };
        lockPassword = true;
        disableSettings = true;
      };
    };
  };
in {
  # Primary group `storage` (gid 666) is what the pool uses for Public and
  # Dropbox; Dropbox is additionally world-writable. The `storage` group
  # definition itself lives in hosts/nixos-file-vm/default.nix and is not
  # touched here.
  users.users.fileweb = {
    isSystemUser = true;
    description = "HDD web file UI";
    group = "storage";
  };

  systemd.services.fileweb = {
    description = "HDD web file UI (FileBrowser Quantum)";
    after = ["local-fs.target" "network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      User = "fileweb";
      Group = "storage";
      ExecStart = "${lib.getExe pkgs.filebrowser-quantum} -c ${fileWebConfig}";
      WorkingDirectory = "/var/lib/fileweb"; # bolt DB + sqlite index live here
      StateDirectory = "fileweb";
      StateDirectoryMode = "0750";
      CacheDirectory = "fileweb";
      CacheDirectoryMode = "0750";
      UMask = "0002";
      Restart = "on-failure";
      RestartSec = 3;

      # Hardening. Public + Dropbox are the only writable filesystem paths;
      # /hdd/Private is made invisible to the service as belt-and-braces on
      # top of it not being configured as a source at all.
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        "/hdd/Dropbox"
        "/var/lib/fileweb"
        "/var/cache/fileweb"
      ];
      # ProtectSystem=strict already leaves /hdd read-only; make the Public
      # read-only guarantee explicit at the OS sandbox level too.
      ReadOnlyPaths = ["/hdd/Public"];
      InaccessiblePaths = ["/hdd/Private"];
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
    virtualHosts.file-web = {
      serverName = "_";
      listen = [
        {
          addr = "0.0.0.0";
          port = 8080;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8081";
        proxyWebsockets = true;
        extraConfig = ''
          # The pool is a NAS: multi-GB files and long .zip streams are normal.
          client_max_body_size 0;
          client_body_timeout 3600s;
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;

          # Trust boundary for quantum's proxy auth (must override inbound).
          # Host / X-Real-IP / X-Forwarded-* come from
          # recommendedProxySettings; re-setting Host here would send it to
          # the backend twice and Go's HTTP parser rejects duplicate Host.
          proxy_set_header X-Remote-User "files";
        '';
      };
    };
  };

  # firewall-open.nix already opens every port on this VM; no extra firewall
  # rule is required. Kept out of the samba/ZFS modules so this new service
  # stays completely self-contained.

  # nginx proxies to fileweb on first use; ordering avoids a transient 502 on
  # boot while the backend (and its bolt DB) comes up.
  systemd.services.nginx = {
    after = lib.mkAfter ["fileweb.service"];
    wants = lib.mkAfter ["fileweb.service"];
  };
}
