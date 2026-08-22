# vLLM model manager for nixos-gpu-vm.
#
# One stdlib-only Python process runs two loopback-only listeners:
#   * control panel + management API on 127.0.0.1:8501
#   * OpenAI-compatible API proxy on  127.0.0.1:8502 -> vLLM backend 127.0.0.1:9001
# nginx terminates TLS on the public ports and proxies to them:
#   * https://<host>:8000  -> management UI + control API
#   * https://<host>:8001  -> OpenAI-compatible model API (streaming enabled)
# No plain-HTTP listener is exposed: every public port is TLS-only
# (listen ... ssl), so cleartext clients get nginx's 400 "plain HTTP to
# HTTPS port" error and no HTTP content is ever served unencrypted.
#
# TLS uses a build-time self-signed certificate (10y) with SANs for
# nixos-gpu-vm / localhost / 192.168.3.200 / 127.0.0.1, following the
# webapp-vm pattern.  The public cert is also served by the manager at
# /ca.crt so clients can install it as trusted.
#
# The manager starts/stops the vLLM-2080Ti-Definitive runtime (TP=2, FP8,
# MTP3, PIECEWISE CUDA graphs) for the models registered in models.json,
# reports VRAM/health status and per-model log tails, and survives manager
# restarts by adopting a still-running backend (KillMode=process).
#
# State (state.json) and backend logs live in /var/lib/vllm-manager (systemd
# StateDirectory, owned by tianyixia).  See README.md for the API and UI docs.
{
  config,
  lib,
  pkgs,
  ...
}: let
  appDir = pkgs.runCommandLocal "vllm-manager-app" {} ''
    mkdir -p "$out/web"
    cp ${./vllm-manager.py} "$out/vllm-manager.py"
    cp ${./models.json} "$out/models.json"
    cp ${./web/index.html} "$out/web/index.html"
    cp ${./web/app.js} "$out/web/app.js"
    cp ${./web/style.css} "$out/web/style.css"
  '';

  publicHost = "nixos-gpu-vm";

  selfSignedCert = pkgs.runCommand "vllm-manager-self-signed-cert" {
    nativeBuildInputs = [pkgs.openssl];
  } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$out/key.pem" \
      -out "$out/cert.pem" \
      -subj "/CN=${publicHost}" \
      -addext "subjectAltName=DNS:${publicHost},DNS:localhost,IP:192.168.3.200,IP:127.0.0.1" \
      >/dev/null 2>&1
  '';
in {
  networking.firewall.allowedTCPPorts = [8000 8001];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    virtualHosts."vllm-mgmt" = {
      default = true;
      addSSL = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 8000;
          ssl = true;
        }
      ];
      sslCertificate = "${selfSignedCert}/cert.pem";
      sslCertificateKey = "${selfSignedCert}/key.pem";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8501";
        extraConfig = ''
          proxy_read_timeout 300s;
        '';
      };
    };

    virtualHosts."vllm-api" = {
      addSSL = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 8001;
          ssl = true;
        }
      ];
      sslCertificate = "${selfSignedCert}/cert.pem";
      sslCertificateKey = "${selfSignedCert}/key.pem";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8502";
        extraConfig = ''
          proxy_http_version 1.1;
          # OpenAI streaming (SSE) must pass through unbuffered.
          proxy_buffering off;
          proxy_read_timeout 1800s;
          proxy_send_timeout 1800s;
          client_max_body_size 512m;
        '';
      };
    };
  };

  # Start nginx only after the manager: the manager releases the legacy
  # public ports during switchovers, and 502s are better than a bind race.
  systemd.services.nginx = {
    after = ["vllm-manager.service"];
    wants = ["vllm-manager.service"];
  };

  systemd.services.vllm-manager = {
    description = "vLLM model manager + OpenAI API proxy (gpu-vm)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "simple";
      User = "tianyixia";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${appDir}/vllm-manager.py";
      WorkingDirectory = "/var/lib/vllm-manager";
      StateDirectory = "vllm-manager";
      Restart = "always";
      RestartSec = 3;
      # Only signal the manager on stop/restart: the vLLM backend it spawned
      # must survive manager restarts (NixOS rebuilds) so the next instance
      # can adopt the still-running backend instead of reloading the model.
      KillMode = "process";
      Environment = [
        "VLLM_MANAGER_APP_DIR=${appDir}"
        "VLLM_MANAGER_CA_CERT=${selfSignedCert}/cert.pem"
      ];
    };
  };
}
