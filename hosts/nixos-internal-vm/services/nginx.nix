{
  config,
  lib,
  pkgs,
  ...
}: {
  # Reverse proxy for the DeepSeek Harness web UI: nginx listens on :8080 and
  # forwards to the local dsh-web service on 127.0.0.1:3080. Plain HTTP for
  # now (internal net); add TLS/self-signed cert later if needed (see the
  # webapp-vm nginx module for the cert pattern).
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."_" = {
      listen = [
        {addr = "0.0.0.0"; port = 8080;}
        {addr = "[::]"; port = 8080;}
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:3080";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [8080];
}
