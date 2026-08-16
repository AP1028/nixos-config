{
  config,
  lib,
  pkgs,
  ...
}: let
  # Public DNS name used both for this VM's self-signed certificate and for
  # Gitea's ROOT_URL. Change this if the webapp VM gets its own DDNS hostname.
  webappPublicHost = "homeserver040322.ddns.net";

  # The webapp VM is now the only reverse proxy for Gitea. Gitea listens on
  # nixos-git-vm over plain HTTP; nginx terminates TLS on :18081.
  giteaUpstream = "http://192.168.3.102:3001";

  # Uptime Kuma still listens on localhost only; nginx exposes it at /monitor
  # on both the HTTP and HTTPS listeners below.
  uptimeKumaUpstream = "http://127.0.0.1:3001";

  # Preserve the original host:port when proxying to Kuma. Its websocket
  # origin check compares the Host header against the browser Origin, and
  # nginx's $host drops the port. ($host:$server_port keeps the gixy
  # host-spoofing check happy, unlike $http_host.)
  uptimeKumaHostHeader = "proxy_set_header Host $host:$server_port;";

  selfSignedCert =
    pkgs.runCommand "nixos-webapp-vm-self-signed-cert" {
      nativeBuildInputs = [pkgs.openssl];
    } ''
      mkdir -p "$out"

      openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$out/key.pem" \
        -out "$out/cert.pem" \
        -subj "/CN=${webappPublicHost}" \
        -addext "subjectAltName=DNS:${webappPublicHost},DNS:nixos-webapp-vm,DNS:localhost,IP:127.0.0.1" \
        >/dev/null 2>&1
    '';
in {
  networking.firewall.allowedTCPPorts = [
    18080
    18081
  ];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    # Used by the 497 handler: plain HTTP on the TLS port redirects to HTTPS
    # except at the bare root, which is intentionally a 404.
    appendHttpConfig = ''
      map $request_uri $plain_http_on_tls_is_root {
        "~^/$" 0;
        default 1;
      }
    '';

    virtualHosts."_" = {
      default = true;

      # addSSL makes nixpkgs emit the ssl_certificate/_key directives even
      # though one of the explicit listen lines below is plain HTTP.
      addSSL = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 18080;
        }
        {
          addr = "0.0.0.0";
          port = 18081;
          ssl = true;
        }
      ];

      sslCertificate = "${selfSignedCert}/cert.pem";
      sslCertificateKey = "${selfSignedCert}/key.pem";

      # 18081 is the TLS listener. Plain HTTP sent to it produces nginx's
      # 497 error. Non-root paths are redirected to HTTPS on the same
      # host/port; the bare root stays a 404 like the HTTP port's root.
      extraConfig = ''
        error_page 497 = @plain_http_on_tls;

        location @plain_http_on_tls {
          if ($plain_http_on_tls_is_root = 0) {
            return 404;
          }
          return 301 https://$host:18081$request_uri;
        }
      '';

      locations = {
        "= /" = {
          return = "404";
        };

        "= /gitea" = {
          # Gitea is HTTPS-only: plain HTTP on 18080 jumps straight to
          # https://host:18081/gitea/ instead of being proxied.
          extraConfig = ''
            if ($scheme = http) {
              return 301 https://$host:18081/gitea/;
            }
            return 308 /gitea/;
          '';
        };

        "/gitea/" = {
          # The trailing slash makes nginx strip /gitea/ before forwarding:
          #   /gitea/foo/bar -> http://192.168.3.102:3001/foo/bar
          proxyPass = "${giteaUpstream}/";
          proxyWebsockets = true;
          extraConfig = ''
            # HTTPS-only proxy: plain HTTP never reaches Gitea.
            if ($scheme = http) {
              return 301 https://$host:18081$request_uri;
            }
          '';
        };

        # Uptime Kuma admin UI lives under /monitor/. Its public status page
        # (slug "public") is /monitor/status/public; /monitor and
        # /monitor/status point there, while the dashboard remains
        # login-gated at /monitor/dashboard.
        "= /monitor" = {
          return = "301 /monitor/status/public";
        };
        "= /monitor/" = {
          return = "301 /monitor/status/public";
        };
        "= /monitor/status" = {
          return = "301 /monitor/status/public";
        };
        "= /monitor/status/" = {
          return = "301 /monitor/status/public";
        };

        "/monitor/" = {
          # Strip /monitor/ before forwarding to Uptime Kuma and rewrite its
          # root-absolute redirects (e.g. Location: /dashboard) so the UI
          # stays under /monitor/.
          proxyPass = "${uptimeKumaUpstream}/";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_redirect / /monitor/;
            ${uptimeKumaHostHeader}
          '';
        };

        # Compatibility redirects for the previous /status/ prefix.
        "= /status" = {
          return = "308 /monitor/";
        };
        "= /status/" = {
          return = "308 /monitor/";
        };
        "= /status/status/public" = {
          return = "301 /monitor/status/public";
        };

        # Uptime Kuma's frontend is built with absolute root paths: assets,
        # API calls and socket.io all go to "/...". Proxy those root prefixes
        # to Kuma so the dashboard reached at /monitor/dashboard works; the
        # bare root itself remains 404 above.
        "/assets/" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "/api/" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "/socket.io/" = {
          proxyPass = "${uptimeKumaUpstream}";
          proxyWebsockets = true;
          extraConfig = uptimeKumaHostHeader;
        };
        "/upload/" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "/screenshots/" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };

        "= /icon.svg" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "= /manifest.json" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "= /apple-touch-icon.png" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "= /favicon.ico" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
        "= /robots.txt" = {
          proxyPass = "${uptimeKumaUpstream}";
          extraConfig = uptimeKumaHostHeader;
        };
      };
    };
  };
}
