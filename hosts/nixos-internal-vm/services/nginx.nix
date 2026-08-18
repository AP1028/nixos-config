{
  config,
  lib,
  pkgs,
  ...
}: let
  # The dsh web UI calls crypto.randomUUID(), which browsers only expose in
  # secure contexts. A self-signed certificate on the LAN makes the UI work
  # without needing to publish it to the public internet.
  internalHost = "nixos-internal-vm";
  internalIp = "192.168.3.105";

  selfSignedCert =
    pkgs.runCommand "nixos-internal-vm-self-signed-cert" {
      nativeBuildInputs = [pkgs.openssl];
    } ''
      mkdir -p "$out"

      openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$out/key.pem" \
        -out "$out/cert.pem" \
        -subj "/CN=${internalHost}" \
        -addext "subjectAltName=DNS:${internalHost},DNS:localhost,IP:${internalIp},IP:127.0.0.1" \
        >/dev/null 2>&1
    '';
in {
  # HTTPS reverse proxies for local services.
  #
  #   https://<host>:8080 -> dsh (127.0.0.1:3080)
  #   https://<host>:8000 -> SillyTavern (127.0.0.1:8001)
  #
  # Both are HTTPS-only and protected by the same htpasswd file. The htpasswd
  # file is intentionally outside the Nix store so the password can be set or
  # replaced imperatively on the VM:
  #
  #   sudo htpasswd -B /var/lib/nginx-auth/htpasswd-dsh tianyixia
  #   sudo systemctl reload nginx
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    virtualHosts = {
      dsh = {
        listen = [
          {addr = "0.0.0.0"; port = 8080; ssl = true;}
          {addr = "[::]"; port = 8080; ssl = true;}
        ];
        addSSL = true;
        sslCertificate = "${selfSignedCert}/cert.pem";
        sslCertificateKey = "${selfSignedCert}/key.pem";
        basicAuthFile = "/var/lib/nginx-auth/htpasswd-dsh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:3080";
          proxyWebsockets = true;
          extraConfig = ''
            # dsh keeps privileged /api methods (settings.describe,
            # credentials.describe, etc.) loopback-only. Since nginx is the
            # authenticated TLS front door, present the upstream as loopback
            # so those methods work through the reverse proxy.
            proxy_set_header Host $proxy_host;
            proxy_set_header Origin http://$proxy_host;
          '';
        };
      };

      sillytavern = {
        listen = [
          {addr = "0.0.0.0"; port = 8000; ssl = true;}
          {addr = "[::]"; port = 8000; ssl = true;}
        ];
        addSSL = true;
        sslCertificate = "${selfSignedCert}/cert.pem";
        sslCertificateKey = "${selfSignedCert}/key.pem";
        basicAuthFile = "/var/lib/nginx-auth/htpasswd-dsh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:8001";
          proxyWebsockets = true;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [8000 8080];

  # Make sure the htpasswd file exists before nginx starts and that the nginx
  # worker can read it. The file is empty until you add a user; nginx will deny
  # access until one is configured.
  systemd.tmpfiles.rules = [
    "d /var/lib/nginx-auth 0750 root nginx -"
    "f /var/lib/nginx-auth/htpasswd-dsh 0640 root nginx -"
  ];
}
