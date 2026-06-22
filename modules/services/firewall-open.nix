{
  config,
  lib,
  pkgs,
  ...
}: {
  # Firewall is enabled for the forward chain (NAT/masquerading), but all inbound
  # TCP and UDP ports are open. Per-service port rules live in their own modules.
  networking.firewall = {
    enable = true;
    allowedTCPPortRanges = [
      {
        from = 1;
        to = 65535;
      }
    ];
    allowedUDPPortRanges = [
      {
        from = 1;
        to = 65535;
      }
    ];
  };
}
