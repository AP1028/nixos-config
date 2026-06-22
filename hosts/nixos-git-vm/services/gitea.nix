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
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = 3001;
        DOMAIN = "homeserver040322.ddns.net";
        ROOT_URL = "https://homeserver040322.ddns.net:3000/";
        START_SSH_SERVER = true;
        SSH_PORT = 2222;
        SSH_LISTEN_PORT = 2222;
      };
    };
  };
  services.caddy = {
    enable = true;
    virtualHosts."homeserver040322.ddns.net:3000" = {
      extraConfig = ''
        tls internal
        reverse_proxy 127.0.0.1:3001
      '';
    };
  };
  networking.firewall.allowedTCPPorts = [3000];
}
