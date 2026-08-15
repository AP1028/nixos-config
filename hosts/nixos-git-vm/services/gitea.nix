{
  config,
  lib,
  pkgs,
  ...
}: {
  services.gitea = {
    enable = true;
    appName = "My Private Git Server";
    database.type = "sqlite3";
    settings = {
      server = {
        HTTP_ADDR = "192.168.3.102"; # only the webapp VM nginx upstream should reach this
        HTTP_PORT = 3001;
        DOMAIN = "homeserver040322.ddns.net";
        # Served through the webapp VM reverse proxy. nginx strips the /gitea
        # prefix before forwarding to HTTP_PORT below.
        ROOT_URL = "https://homeserver040322.ddns.net:18081/gitea/";
        START_SSH_SERVER = true;
        SSH_PORT = 2222;
        SSH_LISTEN_PORT = 2222;
      };
    };
  };
  # Caddy was removed deliberately: nginx on nixos-webapp-vm is now the only
  # reverse proxy for Gitea. It terminates TLS on :18081 and forwards to
  # this VM over plain HTTP on port 3001.
  networking.firewall.allowedTCPPorts = [3001];
}
