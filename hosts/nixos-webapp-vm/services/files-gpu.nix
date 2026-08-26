# Reverse proxy for the nixos-gpu-vm web file UI.
#
# The webapp VM is the WAN access point: its ports 18080 (HTTP) and
# 18081 (HTTPS) are forwarded, and the gpu file UI is reached as
#
#   http://<public-host>:18080/files-gpu/...
#   https://<public-host>:18081/files-gpu/...
#
# nginx keeps the /files-gpu/ prefix intact when forwarding because the
# backend (FileBrowser Quantum on nixos-gpu-vm) is configured with
# baseURL="/files-gpu/". Mirrors services/files.nix for the file-vm UI
# (which uses /files/), with the gpu-vm twin named /files-gpu/.
{
  config,
  lib,
  pkgs,
  ...
}: let
  gpuVmUpstream = "http://192.168.3.200:8080";
in {
  services.nginx.virtualHosts."_".locations = {
    # The UI was briefly published under /file-gpu/ on its first day; keep
    # old bookmarks working.
    "= /file-gpu" = {
      return = "308 /files-gpu/";
    };

    "= /files-gpu" = {
      return = "308 /files-gpu/";
    };

    "/files-gpu/" = {
      # No URI in proxyPass: the original URI (/files-gpu/...) is forwarded
      # unchanged to nixos-gpu-vm, whose own nginx forwards it to the
      # Quantum backend with baseURL /files-gpu/.
      proxyPass = "${gpuVmUpstream}";
      proxyWebsockets = true;
      extraConfig = ''
        # NAS traffic: multi-GB uploads and long .zip streams are normal.
        # Timeouts are 7 days between successive I/O ops (= effectively
        # unlimited for multi-hundred-GB downloads). NOTE: 0 (nginx "no
        # timeout") is NOT used here — nginx reports an instant upstream
        # timeout for the first request when proxy_read/proxy_send_timeout
        # are 0.
        client_max_body_size 0;
        client_body_timeout 604800s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 604800s;
        proxy_send_timeout 604800s;
        send_timeout 604800s;
      '';
    };
  };
}
