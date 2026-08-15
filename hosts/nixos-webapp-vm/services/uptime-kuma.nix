{
  config,
  lib,
  pkgs,
  ...
}: {
  # Uptime Kuma listens only on 127.0.0.1:3001; nginx on this host exposes it
  # at :18080/status/ (HTTP) and :18081/status/ (HTTPS).
  services.uptime-kuma.enable = true;
}
