{
  config,
  pkgs,
  lib,
  ...
}: {
  services.sillytavern = {
    enable = true;
  };
  networking.firewall.allowedTCPPorts = [8000];
}
