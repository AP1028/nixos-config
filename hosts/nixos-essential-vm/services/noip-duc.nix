{
  config,
  lib,
  pkgs,
  ...
}: {
  systemd.services.noip-duc = {
    description = "No-IP Dynamic Update Client";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      EnvironmentFile = "/etc/default/noip-duc";
      ExecStart = "${pkgs.noip}/bin/noip-duc";
      Restart = "on-failure";
      Type = "simple";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };

    environment = {
      NOIP_IP_METHOD = "http://whatismyip.sjtu.edu.cn/";
    };
  };
}
