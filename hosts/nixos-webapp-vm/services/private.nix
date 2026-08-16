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

  # Generic same-origin path normalizer for the non-Proxmox private apps.
  # SillyTavern and dsh both call absolute /api/... paths from JavaScript;
  # this hook prefixes fetch/XHR/WebSocket/EventSource URLs at runtime. It
  # also repoints dsh's __DSH_BOOT__ plugin entries, whose URLs come from an
  # inline JSON blob rather than href/src attributes.
  privatePathHook = prefix:
    lib.removeSuffix "\n" ''
      window.__PRIVATE_BASE__='${prefix}'; (function(){var P=window.__PRIVATE_BASE__; function N(u){if(typeof u!=='string'){return u;} if(/^[a-z][a-z0-9+.-]*:/i.test(u)||/^\/\//.test(u)){return u;} if(u.indexOf(P+'/')===0||u===P){return u;} if(u.charAt(0)==='/'){return P+u;} return u;} if(window.__DSH_BOOT__&&window.__DSH_BOOT__.entries){for(var i=0;i<window.__DSH_BOOT__.entries.length;i++){var e=window.__DSH_BOOT__.entries[i];if(e&&typeof e.url==='string'){e.url=N(e.url);}}} var F=window.fetch; window.fetch=function(){if(arguments.length){arguments[0]=N(arguments[0]);} return F.apply(this,arguments);}; var O=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(){if(arguments.length>1){arguments[1]=N(arguments[1]);} return O.apply(this,arguments);}; if(window.WebSocket){var W=window.WebSocket; window.WebSocket=new Proxy(W,{construct:function(t,a){if(a.length){a[0]=N(a[0]);} return Reflect.construct(t,a);}});} if(window.EventSource){var E=window.EventSource; window.EventSource=new Proxy(E,{construct:function(t,a){if(a.length){a[0]=N(a[0]);} return Reflect.construct(t,a);}});} if(window.URL){var U=window.URL; window.URL=new Proxy(U,{construct:function(t,a){if(a.length>1&&typeof a[0]==='string'&&a[0].charAt(0)==='/'){var b=a[1];var base=b&&typeof b==='object'&&typeof b.href==='string'?b.href:String(b);if(base===window.location.origin||base===window.location.origin+'/'){a[0]=P+a[0];}} return Reflect.construct(t,a);}});}})();
    '';

  # Static HTML/CSS rewrites shared by the non-Proxmox apps. The runtime path
  # hook is injected by each app with a multi-line anchor that only exists in
  # that app's index.html; a bare "</head>" would also match JS bundles that
  # embed HTML template strings and corrupt them.
  webSubFilters = prefix: ''
    proxy_set_header Accept-Encoding "";
    sub_filter_once off;
    sub_filter_types *;

    sub_filter 'href="/' 'href="${prefix}/';
    sub_filter 'src="/' 'src="${prefix}/';
    sub_filter 'action="/' 'action="${prefix}/';
  '';

  sillytavernSubFilters = prefix: ''
    ${webSubFilters prefix}

    # Only these CSS files reference root-absolute url(...) paths. Keep the
    # rewrites exact: nginx sub_filter matching is case-insensitive, so a
    # broad url('/ filter also corrupts `new URL('/...')` in JS modules.
    sub_filter "url('/favicon.ico')" "url('${prefix}/favicon.ico')";
    sub_filter "url('/img/down-arrow.svg')" "url('${prefix}/img/down-arrow.svg')";
    sub_filter "url('/img/times-circle.svg')" "url('${prefix}/img/times-circle.svg')";

    sub_filter '<!-- Scripts are loaded at the end of the body to improve page load speed -->\n</head>' "<script>${privatePathHook prefix}</script><!-- Scripts are loaded at the end of the body to improve page load speed --></head>";

    # SillyTavern's relative asset URLs are all resolved through <base href>.
    # Point it at the subpath and let the runtime hook handle absolute /api
    # calls. This rule must come after the generic href="/" rewrite above so
    # the freshly inserted prefix is not prefixed a second time.
    sub_filter '<base href="/">' '<base href="${prefix}/">';

    # script.js top-level-awaits the window load event before it registers its
    # jQuery ready handler. Behind sub_filter some browsers never fire load
    # (the page stays on the preloader), so resolve that promise immediately.
    sub_filter "window.addEventListener('load', resolve);" "resolve();";

    # A few SillyTavern modules use root-absolute static imports
    # (`from '/script.js'`, `from '/scripts/utils.js'`, ...). Point them back
    # under the subpath so the module graph finishes evaluating.
    sub_filter "from '/" "from '${prefix}/";

    # Image paths set from JS (`splashLogo.src = '/img/logo.png'`, template
    # literals like `/img/<api>.svg`, etc.) bypass href/src attributes.
    sub_filter "'/img/" "'${prefix}/img/";
    sub_filter '"/img/' '"${prefix}/img/';
    sub_filter '`/img/' '`${prefix}/img/';

    # Character/persona avatars are requested as
    # `/thumbnail?type=avatar&file=...`, built in a JS template literal.
    sub_filter '`/thumbnail?' '`${prefix}/thumbnail?';
  '';

  dshSubFilters = prefix: ''
    ${webSubFilters prefix}

    # dsh's Vite CSS uses unquoted url(/assets/fonts/...); exact rewrite so it
    # cannot touch JS `new URL(...)` (sub_filter matching is case-insensitive).
    sub_filter 'url(/assets/' 'url(${prefix}/assets/';

    sub_filter '</head>\n  <body><script>(() => {\n  const preference = "system"' "<script>${privatePathHook prefix}</script></head>\n  <body><script>(() => {\n  const preference = \"system\"";
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

    # noVNC builds wss://hostname:port + "api2/json..." when the host setting
    # is populated, which drops the /private/pveN path. Leave host empty so it
    # resolves the websocket URL against the console page URL instead.
    sub_filter 'UI.initSetting("host", window.location.hostname);' 'UI.initSetting("host", "");';

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

  sillytavernProxyConfig = ''
    ${autheliaAuthRequest}

    proxy_ssl_verify off;
    proxy_redirect / /private/sillytavern/;
    proxy_redirect https://192.168.3.105:8000/ /private/sillytavern/;
    proxy_set_header Host $proxy_host;
    client_max_body_size 0;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    ${sillytavernSubFilters "/private/sillytavern"}
  '';

  dshProxyConfig = ''
    ${autheliaAuthRequest}

    proxy_ssl_verify off;
    proxy_redirect / /private/dsh/;
    proxy_redirect https://192.168.3.105:8080/ /private/dsh/;
    proxy_set_header Host $proxy_host;
    client_max_body_size 0;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    ${dshSubFilters "/private/dsh"}
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
            resources = ["^/private/(pve1|pve2|sillytavern|dsh)(/.*)?$"];
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

    "= /private/sillytavern" = {
      return = "308 /private/sillytavern/";
      extraConfig = privateHttpsOnly;
    };

    "= /private/dsh" = {
      return = "308 /private/dsh/";
      extraConfig = privateHttpsOnly;
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

    "/private/sillytavern/" = {
      proxyPass = "https://192.168.3.105:8000/";
      proxyWebsockets = true;
      # Disable the global recommended proxy headers so our explicit
      # proxy_set_header Host $proxy_host below is not overridden.
      recommendedProxySettings = false;
      extraConfig = sillytavernProxyConfig;
    };

    "/private/dsh/" = {
      proxyPass = "https://192.168.3.105:8080/";
      proxyWebsockets = true;
      recommendedProxySettings = false;
      extraConfig = dshProxyConfig;
    };
  };
}
