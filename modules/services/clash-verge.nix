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

  # Unpinned as of 2.5.2 (fixed the 2.5.1 blank proxy regression, issue #6409).
  # The old-nixpkgs flake input is still kept as a fallback pin if a future
  # version breaks again:
  #   programs.clash-verge.package =
  #     inputs.old-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.clash-verge-rev;

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
