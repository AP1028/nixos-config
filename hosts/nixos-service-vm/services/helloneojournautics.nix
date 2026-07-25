{ pkgs, inputs, ... }:
let
  ysmJava = pkgs.callPackage ../../../packages/ysm-java { };
in {
  systemd.services.helloneojournautics = {
    description = "NeoForge Minecraft Server (ysm-java) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.screen
      ysmJava
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/HelloNeoJournautics";
      ExecStart = "${pkgs.screen}/bin/screen -DmS mc-server ./run.sh";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S mc-server -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
