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
  #
  # We wrap the existing clash-verge C wrapper with another C wrapper
  # (makeBinaryWrapper) that just adds GST_PLUGIN_SYSTEM_PATH.  The
  # original wrapper still handles GIO/GDK/XDG.  Using a C wrapper
  # (not a shell script) keeps the setcap chain intact for TUN mode.
  programs.clash-verge.package = let
    gstPluginPath = lib.concatStringsSep ":" [
      "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0"
      "${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0"
      "${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0"
      "${pkgs.gst_all_1.gstreamer}/lib/gstreamer-1.0"
    ];
  in pkgs.runCommand "clash-verge-rev-gst"
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
            --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${gstPluginPath}"
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
  # If the GStreamer fix above doesn't resolve the blank proxy page,
  # add a pinned nixpkgs input in flake.nix and use it here:
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
