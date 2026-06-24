{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  # Clash Verge (Mihomo) with TUN mode for transparent proxying
  programs.clash-verge = {
    group = "wheel";
    enable = true;
    serviceMode = true; # run as systemd service, survives user logout
    tunMode = true; # virtual network device for system‑wide routing
  };

  # Pin clash-verge-rev to 2.4.7 (2.5.1 has blank proxy regression:
  # "no active proxy nodes" on home page, empty proxies tab).
  # Tracked upstream: github.com/clash-verge-rev/clash-verge-rev/issues/6409
  # programs.clash-verge.package =
  #   inputs.old-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.clash-verge-rev;

  networking.firewall = {
    trustedInterfaces = ["Mihomo"]; # allow TUN traffic through firewall
    extraReversePathFilterRules = ''
      iifname { "Mihomo" } accept comment "allow clash tun"
    '';
    allowedUDPPorts = [53];
    allowedTCPPorts = [53];
  };

  # Point DNS to systemd-resolved stub, then resolve all domains via the proxy
  networking.nameservers = ["127.0.0.53"];
  services.resolved = {
    enable = true;
    settings.Resolve.Domains = lib.mkForce ["~."]; # resolver bypass, clash handles DNS
  };
}
