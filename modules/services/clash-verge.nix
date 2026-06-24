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

  # Pin clash-verge to old nixpkgs (rev 567a49d) — the newer build's
  # WebKitGTK DMABUF renderer breaks on NVIDIA/Wayland, causing blank
  # proxy page and "core communication failed".
  programs.clash-verge.package = inputs.old-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.clash-verge-rev;

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
