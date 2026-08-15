# Reverse proxy for the nixos-file-vm web file UI.
#
# The webapp VM is the WAN access point: its ports 18080 (HTTP) and
# 18081 (HTTPS) are forwarded, and the file UI is reached as
#
#   http://<public-host>:18080/files/...
#   https://<public-host>:18081/files/...
#
# nginx keeps the /files/ prefix intact when forwarding because the backend
# (FileBrowser Quantum on nixos-file-vm) is configured with baseURL="/files/".
{
  config,
  lib,
  pkgs,
  ...
}: let
  fileVmUpstream = "http://192.168.3.104:8080";
in {
  services.nginx.virtualHosts."_".locations = {
    "= /files" = {
      return = "308 /files/";
    };

    "/files/" = {
      # No URI in proxyPass: the original URI (/files/...) is forwarded
      # unchanged to nixos-file-vm, whose own nginx forwards it to the
      # Quantum backend with baseURL /files/.
      proxyPass = "${fileVmUpstream}";
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
