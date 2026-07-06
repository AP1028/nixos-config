{
  config,
  lib,
  pkgs,
  ...
}: let
  uudeck = pkgs.callPackage ../../packages/uudeck.nix {};
  # The plugin spawns ./xuplugin-guardian relative to its cwd, so run from the
  # package's libexec dir where the guardian lives (read + exec only; no writes
  # land here thanks to the patched absolute UUID path).
  workdir = "${uudeck}/libexec/uudeck";
in {
  # Preload the modules the plugin would otherwise try to modprobe itself:
  # TUN for the tunnel device, conntrack netlink for its NAT bookkeeping.
  boot.kernelModules = ["tun" "nfnetlink" "nf_conntrack_netlink"];

  systemd.services.uuplugin = {
    description = "NetEase UU Accelerator (Steam Deck plugin)";
    wants = ["network-online.target"];
    after = ["network-online.target"];
    # Not started at boot; run `systemctl start uuplugin` when you want to
    # accelerate, or add wantedBy = ["multi-user.target"] to autostart.
    serviceConfig = {
      Type = "simple";
      ExecStart = "${uudeck}/bin/uudeck ${workdir}/uu.conf";
      WorkingDirectory = workdir;
      # Persistent device UUID lives here (the binary is patched to write
      # /var/lib/uu/.uuplugin_uuid) so pairings survive reboots.
      StateDirectory = "uu";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # The UU phone app pairs with the Deck over the LAN on port 16363. The host
  # firewall is already fully open on this machine, but declare it explicitly so
  # this module stays self-contained.
  networking.firewall.allowedTCPPorts = [16363];
  networking.firewall.allowedUDPPorts = [16363];

  # NOTE on self-update: the binary occasionally checks router.uu.163.com and, if
  # a newer version exists, downloads a fresh uuplugin from uurouter.gdl.netease.com
  # into /tmp/uu and re-execs it. We do NOT block that host — it is also used by the
  # plugin's own connectivity/registration probe, so blackholing it makes the app
  # report "failed to connect to internet". If an upstream update does swap the
  # binary, worst case is a one-time re-pair in the app; bump version + hash in
  # packages/uudeck.nix to move to the new version on the Nix side.
}
