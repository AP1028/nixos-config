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

    # Fix GStreamer plugins missing (appsink etc) — the Nix wrapper
    # doesn't set GST_PLUGIN_SYSTEM_PATH, so WebKitGTK can't render.
    # Also force software rendering via Mesa (llvmpipe) to avoid
    # EGL/DRI2 failures when Mesa gets dGPU fds from the compositor.
    package = pkgs.runCommand "clash-verge-rev-gst-fixed"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        inherit (pkgs.clash-verge-rev) meta;
      } ''
      mkdir -p $out/bin
      for bin in ${pkgs.clash-verge-rev}/bin/*; do
        ln -s $bin $out/bin/$(basename $bin)
      done
      rm $out/bin/clash-verge
      makeWrapper ${pkgs.clash-verge-rev}/bin/.clash-verge-wrapped $out/bin/clash-verge \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0" \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0" \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0" \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${pkgs.gst_all_1.gstreamer}/lib/gstreamer-1.0" \
        --set LIBGL_ALWAYS_SOFTWARE 1
    '';
  };

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
