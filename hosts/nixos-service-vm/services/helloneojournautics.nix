{ pkgs, inputs, ... }:
let
  ysmJava = pkgs.callPackage ../../../packages/ysm-java { };
in {
  systemd.services.hello-neo-journautics = {
    description = "NeoForge Minecraft Server (ysm-java) in Screen";
    after = ["network.target"];
    path = [
      pkgs.screen
      ysmJava
      pkgs.bash
    ];
    serviceConfig = {
      Type = "forking";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/HelloNeoJournautics";
      ExecStart = "${pkgs.screen}/bin/screen -dmS helloneojournautics ./run.sh";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S helloneojournautics -X eval 'stuff \"stop\"\\015'";
      Environment = "TERM=xterm-256color";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
