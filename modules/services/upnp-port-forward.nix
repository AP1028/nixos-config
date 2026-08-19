{
  pkgs,
  ...
}: let
  upnp = pkgs.callPackage ../../packages/upnp-port-forward.nix {};
in {
  environment.systemPackages = [upnp];

  # Maintain the Moonlight/Sunshine UPnP forwards without router admin access.
  # A timer re-runs the check so mappings survive router reboots / lease drops.
  systemd.services.upnp-port-forward-moonlight = {
    description = "Maintain Moonlight/Sunshine UPnP port mappings";
    wants = ["network-online.target"];
    after = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${upnp}/bin/upnp-port-forward ensure-moonlight";
      Environment = "UPNP_LOCAL_IP=192.168.1.100";
    };
  };

  systemd.timers.upnp-port-forward-moonlight = {
    description = "Periodically maintain Moonlight/Sunshine UPnP port mappings";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
