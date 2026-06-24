{
  config,
  lib,
  pkgs,
  ...
}: {
  # Clash Verge (Mihomo) with TUN mode for transparent proxying
  programs.clash-verge = {
    group = "wheel";
    enable = true;
    serviceMode = true; # run as systemd service, survives user logout
    tunMode = true; # virtual network device for system‑wide routing
  };

  # Fix clash-verge GUI rendering (blank proxy page / core communication
  # failed): WebKitGTK's DMABUF renderer fails on NVIDIA/Wayland systems,
  # producing "AcceleratedSurfaceDMABuf was unable to construct a complete
  # framebuffer".  This makes the webview render blank — the proxy page
  # shows nothing and the frontend JS never loads.
  #
  # WEBKIT_DISABLE_DMABUF_RENDERER=1 forces a fallback renderer that
  # works on NVIDIA.  We wrap only the GUI binary with a C wrapper
  # (makeBinaryWrapper) to keep the setcap chain intact for TUN mode.
  programs.clash-verge.package = pkgs.runCommand "clash-verge-rev-dmabuf"
    {
      nativeBuildInputs = [pkgs.makeBinaryWrapper];
      inherit (pkgs.clash-verge-rev) meta;
    }
    ''
      mkdir -p $out/bin
      for bin in ${pkgs.clash-verge-rev}/bin/*; do
        name=$(basename "$bin")
        if [ "$name" = "clash-verge" ]; then
          makeBinaryWrapper "$bin" $out/bin/clash-verge \
            --inherit-argv0 \
            --set WEBKIT_DISABLE_DMABUF_RENDERER 1
        elif [ -L "$bin" ]; then
          ln -s "$(readlink "$bin")" $out/bin/"$name"
        else
          cp "$bin" $out/bin/"$name"
        fi
      done
      for d in share lib; do
        if [ -d ${pkgs.clash-verge-rev}/$d ]; then
          ln -s ${pkgs.clash-verge-rev}/$d $out/$d
        fi
      done
    '';

  # ── Fallback: pin clash-verge to old nixpkgs ────────────────────
  # If this fix doesn't resolve the issue, add a pinned nixpkgs input
  # in flake.nix and use it here:
  #   programs.clash-verge.package = inputs.old-nixpkgs.clash-verge-rev;
  # Where old-nixpkgs.url = "github:NixOS/nixpkgs/567a49d";

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
