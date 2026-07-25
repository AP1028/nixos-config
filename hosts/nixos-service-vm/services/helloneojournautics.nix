{ pkgs, inputs, ... }:
let
  ysmJava = pkgs.callPackage ../../../packages/ysm-java { };
in {
  systemd.services.hello-neo-journautics = {
    description = "NeoForge Minecraft Server (ysm-java) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      ysmJava
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/HelloNeoJournautics";
      ExecStart = "screen -DmS helloneojournautics ./run.sh";
      ExecStop = "screen -p 0 -S helloneojournautics -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
