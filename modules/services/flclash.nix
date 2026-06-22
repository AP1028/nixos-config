{
  config,
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = [pkgs.flclash];
  networking.firewall = {
    trustedInterfaces = ["Mihomo"];
    extraReversePathFilterRules = ''
      iifname { "Mihomo" } accept comment "allow clash tun"
    '';
    allowedUDPPorts = [53];
    allowedTCPPorts = [53];
  };
  networking.nameservers = ["127.0.0.1"];
  services.resolved.enable = true;
}
