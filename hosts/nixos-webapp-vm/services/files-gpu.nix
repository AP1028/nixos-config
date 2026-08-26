# Reverse proxy for the nixos-gpu-vm web file UI.
#
# The webapp VM is the WAN access point: its ports 18080 (HTTP) and
# 18081 (HTTPS) are forwarded, and the gpu file UI is nested under the
# /files/ namespace, next to the file-vm UI (services/files.nix):
#
#   /files/Public      /files/Dropbox      -> nixos-file-vm (192.168.3.104)
#   /files/files-gpu/  ...                 -> nixos-gpu-vm  (192.168.3.200)
#
#   http://<public-host>:18080/files/files-gpu/...
#   https://<public-host>:18081/files/files-gpu/...
#
# nginx keeps the /files/files-gpu/ prefix intact when forwarding because
# the backend (FileBrowser Quantum on nixos-gpu-vm) is configured with
# baseURL="/files/files-gpu/". nginx longest-prefix matching routes
# /files/files-gpu/... here and everything else under /files/ to the
# file-vm upstream.
{
  config,
  lib,
  pkgs,
  ...
}: let
  gpuVmUpstream = "http://192.168.3.200:8080";
in {
  services.nginx.virtualHosts."_".locations = {
    # The UI was briefly published at /file-gpu/ and /files-gpu/ before the
    # /files/files-gpu/ rename; keep old bookmarks working.
    "= /file-gpu" = {
      return = "308 /files/files-gpu/";
    };
    "= /file-gpu/" = {
      return = "308 /files/files-gpu/";
    };
    "= /files-gpu" = {
      return = "308 /files/files-gpu/";
    };
    "= /files-gpu/" = {
      return = "308 /files/files-gpu/";
    };

    "/files/files-gpu/" = {
      # No URI in proxyPass: the original URI (/files/files-gpu/...) is
      # forwarded unchanged to nixos-gpu-vm, whose own nginx forwards it to
      # the Quantum backend with baseURL /files/files-gpu/.
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
