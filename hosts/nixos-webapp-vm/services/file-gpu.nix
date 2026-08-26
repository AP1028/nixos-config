# Reverse proxy for the nixos-gpu-vm web file UI.
#
# The webapp VM is the WAN access point: its ports 18080 (HTTP) and
# 18081 (HTTPS) are forwarded, and the gpu file UI is reached as
#
#   http://<public-host>:18080/file-gpu/...
#   https://<public-host>:18081/file-gpu/...
#
# nginx keeps the /file-gpu/ prefix intact when forwarding because the
# backend (FileBrowser Quantum on nixos-gpu-vm) is configured with
# baseURL="/file-gpu/". Mirrors services/files.nix for the file-vm UI.
{
  config,
  lib,
  pkgs,
  ...
}: let
  gpuVmUpstream = "http://192.168.3.200:8080";
in {
  services.nginx.virtualHosts."_".locations = {
    "= /file-gpu" = {
      return = "308 /file-gpu/";
    };

    "/file-gpu/" = {
      # No URI in proxyPass: the original URI (/file-gpu/...) is forwarded
      # unchanged to nixos-gpu-vm, whose own nginx forwards it to the
      # Quantum backend with baseURL /file-gpu/.
      proxyPass = "${gpuVmUpstream}";
      proxyWebsockets = true;
      extraConfig = ''
        # NAS traffic: multi-GB uploads and long .zip streams are normal.
        client_max_body_size 0;
        client_body_timeout 3600s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
