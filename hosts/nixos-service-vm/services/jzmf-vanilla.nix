{ pkgs, inputs, ... }: {
  systemd.services.jzmf-vanilla = {
    description = "jzmf-vanilla Minecraft Server (Temurin 25) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.screen
      pkgs.temurin-bin-25
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-vanilla";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo START > /tmp/vanilla-debug.log; env >> /tmp/vanilla-debug.log; pwd >> /tmp/vanilla-debug.log; ls -la ./run.sh >> /tmp/vanilla-debug.log 2>&1; echo \"--- running run.sh ---\" >> /tmp/vanilla-debug.log; ./run.sh >> /tmp/vanilla-debug.log 2>&1; echo \"exit: $?\" >> /tmp/vanilla-debug.log'";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S jzmf-vanilla -X eval 'stuff \"stop\"\\015'";
      Environment = "TERM=xterm-256color";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
