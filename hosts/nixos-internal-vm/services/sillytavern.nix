{
  config,
  pkgs,
  lib,
  ...
}: {
  # SillyTavern listens on localhost only; nginx exposes it as HTTPS on :8000
  # and handles Basic Auth there, so SillyTavern's own password auth is
  # disabled in config-persistent.yaml.
  services.sillytavern = {
    enable = true;
    port = 8001;
    listenAddressIPv4 = "127.0.0.1";
    listen = false;
    configFile = "/var/lib/SillyTavern/config-persistent.yaml";
  };
}
