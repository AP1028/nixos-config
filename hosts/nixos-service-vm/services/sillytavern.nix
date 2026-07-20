{
  config,
  pkgs,
  lib,
  ...
}: {
  services.sillytavern = {
    enable = true;
    port = 8000;
    configFile = "/var/lib/SillyTavern/config-persistent.yaml";
  };
  networking.firewall.allowedTCPPorts = [8000];
}
