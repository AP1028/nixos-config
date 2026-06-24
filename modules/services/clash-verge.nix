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

  # Fix blank proxy page on KDE Wayland + NVIDIA: WebKitGTK's native
  # Wayland rendering (DMABUF) is broken on NVIDIA drivers.  Force
  # XWayland fallback which renders correctly.
  # https://www.clashverge.dev/faq/linux.html#badwindow-invalid-window-parameter
  programs.clash-verge.package = pkgs.runCommand "clash-verge-rev-x11"
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
            --set GDK_BACKEND x11 \
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
