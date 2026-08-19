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

  # SillyTavern's Node server calls the vLLM API directly; give it the LAN
  # self-signed cert bundle so the OpenAI-compatible connection to
  # homeserver040322.ddns.net:18081 verifies. The bundle lives in the ST
  # state dir because the service runs as user "sillytavern" and cannot read
  # tianyixia's 0600 home copy.
  systemd.services.sillytavern.environment.NODE_EXTRA_CA_CERTS = "/var/lib/SillyTavern/vllm-ca-bundle.crt";
}
