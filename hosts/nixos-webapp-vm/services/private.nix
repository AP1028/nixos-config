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
#   HASH=$(authelia crypto hash generate argon2 --password 'YOUR_PASSWORD')
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
  privateBase = "https://192.168.3.152:18081/private/";

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

  pveProxyConfig = ''
    ${autheliaAuthRequest}

    proxy_ssl_verify off;
    proxy_redirect / /private/pve1/;
    proxy_redirect https://192.168.3.10:8006/ /private/pve1/;
    proxy_set_header Host $proxy_host;
    client_max_body_size 0;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
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
  '';
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
        cookies = [
          {
            domain = "192.168.3.152";
            authelia_url = privateBase;
            default_redirection_url = "${privateBase}pve1/";
          }
        ];
      };
      authentication_backend.file = {
        path = "/var/lib/authelia-main/users.yml";
        watch = true;
      };
      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = "192.168.3.152";
            policy = "one_factor";
            resources = ["^/private/(pve1|pve2)(/.*)?$"];
          }
        ];
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
    if [ ! -e /var/lib/authelia-main/users.yml ]; then
      printf 'users: {}\n' > /var/lib/authelia-main/users.yml
      chown authelia-main:authelia-main /var/lib/authelia-main/users.yml
      chmod 600 /var/lib/authelia-main/users.yml
    fi
  '';

  environment.systemPackages = [pkgs.authelia];

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
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Host $host:$server_port;
      '';
    };

    # Internal nginx subrequest target used by auth_request above.
    "/internal/authelia/authz" = {
      extraConfig = ''
        internal;
        proxy_pass http://127.0.0.1:9091/api/authz/auth-request;
        proxy_pass_request_body off;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Original-URL $scheme://$host$request_uri;
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
