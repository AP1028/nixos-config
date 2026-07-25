{ pkgs, inputs, ... }:
let
  ysmJava = pkgs.callPackage ../../../packages/ysm-java { };
in {
  systemd.services.hello-neo-journautics = {
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
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo START > /tmp/hnj-debug.log; env >> /tmp/hnj-debug.log; pwd >> /tmp/hnj-debug.log; ls -la ./run.sh >> /tmp/hnj-debug.log 2>&1; echo \"--- running run.sh ---\" >> /tmp/hnj-debug.log; ./run.sh >> /tmp/hnj-debug.log 2>&1; echo \"exit: $?\" >> /tmp/hnj-debug.log'";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S helloneojournautics -X eval 'stuff \"stop\"\\015'";
      Environment = "TERM=xterm-256color";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
