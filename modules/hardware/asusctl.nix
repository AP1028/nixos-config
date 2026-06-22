{
  config,
  lib,
  pkgs,
  ...
}: {
  services.asusd = {
    enable = true;
  };

  # asusd writes LED/fan curves to /etc/asusd — relax systemd sandbox to allow this
  systemd.services.asusd.serviceConfig = {
    ProtectSystem = lib.mkForce "full";
    ReadOnlyPaths = lib.mkForce [];
  };
}
