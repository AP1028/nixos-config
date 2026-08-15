{
  config,
  lib,
  pkgs,
  ...
}: {
  # Installed, but intentionally not exposed through nginx yet. Uptime Kuma
  # listens on 127.0.0.1:3001 until a reverse-proxy path/domain is chosen.
  services.uptime-kuma.enable = true;
}
