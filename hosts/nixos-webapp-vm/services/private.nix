# HTTPS-only private services area, protected by an Authelia login portal.
#
#   /private/            -> Authelia login portal (pretty, remember-me)
#   /private/pve1/       -> https://192.168.3.10:8006/  (Proxmox VE 1)
#   /private/pve2/       -> https://192.168.3.100:8006/ (Proxmox VE 2)
#
# Secrets are NOT stored in nixos-config. Authelia generates its own
# jwt/storage/session secrets in /var/lib/authelia-main on first start, and the
# password database is /var/lib/authelia-main/users.yml. To set the first user
# password run (as root, imperatively):
#
#   HASH=$(authelia crypto hash generate argon2 --password 'YOUR_PASSWORD' --no-confirm)
#   printf 'users:\n  admin:\n    displayname: Admin\n    password: %s\n    email: admin@local\n    groups: [admins]\n' "$HASH" > /var/lib/authelia-main/users.yml
#   chown authelia-main:authelia-main /var/lib/authelia-main/users.yml
#   chmod 600 /var/lib/authelia-main/users.yml
#
# then restart the service:
#   systemctl restart authelia-main
{
  config,
  lib,
  pkgs,
  ...
}: let
  autheliaAddress = "tcp://127.0.0.1:9091/private";
  # Hostnames the private area is served on. Authelia needs a session-cookie
  # config and an access-control rule for each one, otherwise the portal's
  # /api/state call fails with "no configured session cookie domain matches".
  #
  # The LAN IP is the only domain in the public repo. Additional public
  # domains are supplied imperatively, one per line, in the runtime file
  # below (created with sudo-env on the VM, never committed):
  #
  #   echo your.domain.tld > /var/lib/authelia-main/public-domains
  #
  # Rebuild with --impure after changing it so the new domain is baked into
  # the generated Authelia config.
  privateDomainsFile = "/var/lib/authelia-main/public-domains";
  privateDomains =
    [
      "192.168.3.152"
    ]
    ++ lib.optionals (builtins.pathExists privateDomainsFile) (
      lib.filter (domain: domain != "") (
        lib.splitString "\n" (builtins.readFile privateDomainsFile)
      )
    );

  privateHttpsOnly = ''
    if ($scheme = http) {
      return 301 https://$host:18081$request_uri;
    }
  '';

  autheliaAuthRequest = ''
    ${privateHttpsOnly}

    auth_request /internal/authelia/authz;
    auth_request_set $redirection_url $upstream_http_location;
    error_page 401 =302 $redirection_url;
  '';

  # Proxmox VE's web UI is written for "/" and hardcodes absolute root paths
  # (/pve2/..., /pwt/..., /api2/..., /nodes/...). nginx's sub_filter rewrites
  # those into /private/pve1 or /private/pve2 so the UI stays on its own
  # subpath and both PVE nodes can coexist on the same HTTPS port.
  pveSubFilters = prefix: let
    # Runtime URL normalizer injected into the PVE index page. PVE builds API
    # URLs out of bare fragments like "/nodes/..." or "/api2/json..."; the
    # hook prefixes same-origin absolute paths in Ext.Ajax and raw
    # XMLHttpRequest calls. That avoids double-prefixing paths PVE composes
    # at runtime (e.g. "/api2/json" + baseUrl), which broke the realm list.
    ajaxHook = lib.removeSuffix "\n" ''
      window.__PVE_SUBPATH__='${prefix}'; (function(){var P=window.__PVE_SUBPATH__; function N(u){if(typeof u!=='string'){return u;} if(/^[a-z][a-z0-9+.-]*:/i.test(u)||/^\/\//.test(u)){return u;} if(u.indexOf(P+'/')===0||u===P){return u;} if(u.charAt(0)==='/'){return P+u;} return u;} var R=Ext.Ajax.request; Ext.Ajax.request=function(o){if(o&&typeof o.url==='string'){o.url=N(o.url);} return R.apply(this,arguments);}; var O=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(m,u){arguments[1]=N(u); return O.apply(this,arguments);}; var W=window.open; window.open=function(u){if(typeof u==='string'&&u.charAt(0)==='?'){arguments[0]=P+'/'+u;} return W.apply(this,arguments);};})();
    '';
  in ''
    # Proxmox gzips its assets; sub_filter needs the plain stream.
    proxy_set_header Accept-Encoding "";
    sub_filter_once off;
    sub_filter_types *;

    # HTML/CSS asset URLs.
    sub_filter 'href="/' 'href="${prefix}/';
    sub_filter 'src="/' 'src="${prefix}/';
    sub_filter 'action="/' 'action="${prefix}/';
    sub_filter 'url("/' 'url("${prefix}/';
    sub_filter "url('/" "url('${prefix}/";

    # The header logo is built in JS as "/pve2" + "/images/proxmox_logo.png".
    sub_filter "let prefix = me.prefix !== undefined ? me.prefix : '/pve2';" "let prefix = me.prefix !== undefined ? me.prefix : '${prefix}/pve2';";

    # Inject the request normalizer right after the inline Proxmox setup
    # object, before proxmoxlib.js runs.
    sub_filter "ConsentText: '''\n    };" "ConsentText: '''\n    }; ${ajaxHook}";

    # PVE opens console windows with window.open('?console=...'), which some
    # browsers resolve against the origin root. Make the subpath explicit.
    sub_filter "'?' + url," "window.__PVE_SUBPATH__ + '/?' + url,";

    # noVNC/xtermjs console pages do not use Ext.Ajax; fix their raw
    # XMLHttpRequest and websocket path builders directly.
    sub_filter 'xhr.open(reqOpts.method, "/api2/json"' 'xhr.open(reqOpts.method, "${prefix}/api2/json"';
    sub_filter "'/api2/json' + url + '/vncwebsocket" "'${prefix}/api2/json' + url + '/vncwebsocket";
    sub_filter 'await l10n.setup(LINGUAS, "/novnc/app/locale/")' 'await l10n.setup(LINGUAS, "${prefix}/novnc/app/locale/")';
    sub_filter 'await fetch("/novnc/package.json")' 'await fetch("${prefix}/novnc/package.json")';
    sub_filter 'import UI from "/novnc/' 'import UI from "${prefix}/novnc/';

    # Spice download links are plain anchors, not Ext.Ajax requests.
    sub_filter "let url = '/nodes/' + nodename + '/spiceshell';" "let url = '${prefix}/nodes/' + nodename + '/spiceshell';";
    sub_filter "url = '/nodes/' + nodename + '/qemu/' + vmid.toString() + '/spiceproxy';" "url = '${prefix}/nodes/' + nodename + '/qemu/' + vmid.toString() + '/spiceproxy';";
    sub_filter "url = '/nodes/' + nodename + '/lxc/' + vmid.toString() + '/spiceproxy';" "url = '${prefix}/nodes/' + nodename + '/lxc/' + vmid.toString() + '/spiceproxy';";
  '';

  pveProxyConfig = ''
    ${autheliaAuthRequest}

    proxy_ssl_verify off;
    proxy_redirect / /private/pve1/;
    proxy_redirect https://192.168.3.10:8006/ /private/pve1/;
    proxy_set_header Host $proxy_host;
    client_max_body_size 0;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    ${pveSubFilters "/private/pve1"}
  '';

  pve2ProxyConfig = ''
    ${autheliaAuthRequest}

    proxy_ssl_verify off;
    proxy_redirect / /private/pve2/;
    proxy_redirect https://192.168.3.100:8006/ /private/pve2/;
    proxy_set_header Host $proxy_host;
    client_max_body_size 0;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    ${pveSubFilters "/private/pve2"}
  '';

  # Imperative password setter. It takes the plaintext password as argv,
  # hashes it at runtime, and writes it to the runtime users database. No
  # password or hash ever enters nixos-config or the nix store.
  autheliaSetUser = pkgs.writeShellApplication {
    name = "authelia-set-user";
    runtimeInputs = [
      pkgs.authelia
      pkgs.coreutils
      pkgs.gnused
      pkgs.systemd
    ];
    text = ''
            set -euo pipefail
            if [ "''${1:-}" = "" ]; then
              echo "usage: sudo authelia-set-user <password>" >&2
              exit 1
            fi
            file=/var/lib/authelia-main/users.yml
            hash=$(authelia crypto hash generate argon2 --password "$1" --no-confirm | sed -n 's/^Digest: //p')
            if [ -z "$hash" ]; then
              echo "failed to generate password hash" >&2
              exit 1
            fi
            cat > "$file" <<EOF
      users:
        tianyixia:
          disabled: false
          displayname: tianyixia
          password: "$hash"
          email: tianyixia@local
          groups: [admins]
      EOF
            chown authelia-main:authelia-main "$file"
            chmod 600 "$file"
            systemctl restart authelia-main
            echo "Authelia user 'tianyixia' updated and authelia-main restarted."
    '';
  };
in {
  services.authelia.instances.main = {
    enable = true;
    secrets = {
      jwtSecretFile = "/var/lib/authelia-main/jwt_secret";
      storageEncryptionKeyFile = "/var/lib/authelia-main/storage_encryption_key";
      sessionSecretFile = "/var/lib/authelia-main/session_secret";
    };
    settings = {
      theme = "dark";
      log = {
        level = "info";
        format = "text";
      };
      server = {
        address = autheliaAddress;
        endpoints.authz.auth-request = {
          implementation = "AuthRequest";
          authn_strategies = [{name = "CookieSession";}];
        };
      };
      session = {
        name = "authelia_session";
        same_site = "lax";
        inactivity = "1M";
        expiration = "3M";
        remember_me = "6M";
        cookies =
          map (domain: {
            inherit domain;
            authelia_url = "https://${domain}:18081/private/";
            default_redirection_url = "https://${domain}:18081/private/pve1/";
          })
          privateDomains;
      };
      authentication_backend.file = {
        path = "/var/lib/authelia-main/users.yml";
        watch = true;
      };
      access_control = {
        default_policy = "deny";
        rules =
          map (domain: {
            inherit domain;
            policy = "one_factor";
            resources = ["^/private/(pve1|pve2)(/.*)?$"];
          })
          privateDomains;
      };
      storage.local.path = "/var/lib/authelia-main/db.sqlite3";
      notifier.filesystem.filename = "/var/lib/authelia-main/notifications.txt";
    };
  };

  # Generate local secrets on first start; never bake secrets into the repo.
  # mkBefore makes this run before Authelia's own validate-config preStart.
  systemd.services.authelia-main.preStart = lib.mkBefore ''
        umask 077
        if [ ! -s /var/lib/authelia-main/jwt_secret ]; then
          ${pkgs.openssl}/bin/openssl rand -base64 48 > /var/lib/authelia-main/jwt_secret
        fi
        if [ ! -s /var/lib/authelia-main/storage_encryption_key ]; then
          ${pkgs.openssl}/bin/openssl rand -base64 48 > /var/lib/authelia-main/storage_encryption_key
        fi
        if [ ! -s /var/lib/authelia-main/session_secret ]; then
          ${pkgs.openssl}/bin/openssl rand -base64 48 > /var/lib/authelia-main/session_secret
        fi
        chown authelia-main:authelia-main \
          /var/lib/authelia-main/jwt_secret \
          /var/lib/authelia-main/storage_encryption_key \
          /var/lib/authelia-main/session_secret 2>/dev/null || true
        chmod 600 \
          /var/lib/authelia-main/jwt_secret \
          /var/lib/authelia-main/storage_encryption_key \
          /var/lib/authelia-main/session_secret
        if [ ! -e /var/lib/authelia-main/users.yml ] || grep -q '^users: {}$' /var/lib/authelia-main/users.yml || grep -q 'password: "Digest:' /var/lib/authelia-main/users.yml; then
          placeholder_hash="$(${pkgs.authelia}/bin/authelia crypto hash generate argon2 --password 'disabled-placeholder' --no-confirm | sed -n 's/^Digest: //p')"
          cat > /var/lib/authelia-main/users.yml <<EOF
    users:
      __placeholder__:
        disabled: true
        displayname: "Placeholder - replace with a real user"
        password: "$placeholder_hash"
        email: placeholder@invalid.local
        groups: []
    EOF
          chown authelia-main:authelia-main /var/lib/authelia-main/users.yml 2>/dev/null || true
          chmod 600 /var/lib/authelia-main/users.yml
        fi
  '';

  environment.systemPackages = [pkgs.authelia autheliaSetUser];

  # Safety net for console windows that still resolve to the bare root
  # (e.g. tabs with pre-fix JS cached). Map the PVE node name from the
  # query string back to its /private/pveN prefix.
  services.nginx.appendHttpConfig = ''
    map $arg_node $private_pve_console_prefix {
      default /private/pve1;
      pve /private/pve2;
    }
  '';

  services.nginx.virtualHosts."_".locations = {
    "= /private" = {
      return = "308 /private/";
      extraConfig = privateHttpsOnly;
    };

    # Authelia login portal at /private/. Must stay outside the auth_request
    # guard or the login page would protect itself.
    "/private/" = {
      proxyPass = "http://127.0.0.1:9091";
      proxyWebsockets = true;
      extraConfig = ''
        ${privateHttpsOnly}
        proxy_redirect http:// https://;
        proxy_set_header X-Forwarded-Proto https;
        # Include the port: Authelia uses this header to build absolute URLs
        # for its portal (https://host:18081/private/...).
        proxy_set_header X-Forwarded-Host $host:$server_port;
        proxy_set_header X-Forwarded-Port $server_port;
      '';
    };

    # Internal nginx subrequest target used by auth_request above.
    "/internal/authelia/authz" = {
      extraConfig = ''
        internal;
        proxy_pass http://127.0.0.1:9091/api/authz/auth-request;
        proxy_pass_request_body off;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Original-URL $scheme://$host:$server_port$request_uri;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Content-Length "";
        proxy_http_version 1.1;
      '';
    };

    "/private/pve1/" = {
      proxyPass = "https://192.168.3.10:8006/";
      proxyWebsockets = true;
      extraConfig = pveProxyConfig;
    };

    "/private/pve2/" = {
      proxyPass = "https://192.168.3.100:8006/";
      proxyWebsockets = true;
      extraConfig = pve2ProxyConfig;
    };
  };
}
