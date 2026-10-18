{
  config,
  lib,
  pkgs,
  ...
}: {
  # SillyTavern serves on localhost only (no nginx on this host); data and
  # config are ported from nixos-internal-vm (192.168.3.105:/var/lib/SillyTavern)
  # and keep the same StateDirectory layout as there.
  services.sillytavern = {
    enable = true;
    port = 8001;
    listenAddressIPv4 = "127.0.0.1";
    listen = false;
    configFile = "/var/lib/SillyTavern/config-persistent.yaml";
  };

  # Default off: the unit is installed but not started at boot.
  # Turn it on with `sudo systemctl start sillytavern`.
  systemd.services.sillytavern.wantedBy = lib.mkForce [];

  # Chats in the ported data call the LAN vLLM endpoint, whose TLS cert is
  # self-signed; trust the same bundle the source host used (copied with the
  # data directory).
  systemd.services.sillytavern.environment.NODE_EXTRA_CA_CERTS = "/var/lib/SillyTavern/vllm-ca-bundle.crt";
}
