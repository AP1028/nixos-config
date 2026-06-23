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
  # failed): the Nix wrapper doesn't set GST_PLUGIN_SYSTEM_PATH, so
  # WebKitGTK can't find GStreamer plugins like "appsink" at runtime.
  # This breaks the webview — the proxy page stays blank and the frontend
  # JS never loads, causing "core communication failed".
  environment.variables = {
    GST_PLUGIN_SYSTEM_PATH_1_0 =
      "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gstreamer}/lib/gstreamer-1.0";
    GST_PLUGIN_SYSTEM_PATH =
      "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0:"
    + "${pkgs.gst_all_1.gstreamer}/lib/gstreamer-1.0";
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
