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

      locations = {
        "= /gitea" = {
          return = "308 /gitea/";
        };

        "/gitea/" = {
          # The trailing slash makes nginx strip /gitea/ before forwarding:
          #   /gitea/foo/bar -> http://192.168.3.102:3001/foo/bar
          proxyPass = "${giteaUpstream}/";
          proxyWebsockets = true;
        };
      };
    };
  };
}
