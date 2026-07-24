{
  pkgs,
  inputs,
  ...
}: let
  ysmJava = pkgs.callPackage ../../../packages/ysm-java { };
in {
  systemd.services = {
    hello-neo-journautics = {
      description = "NeoForge Minecraft Server (ysm-java) in Tmux";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.tmux
        ysmJava
        pkgs.bash
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "forking";
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/HelloNeoJournautics";
        ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.tmux}/bin/tmux kill-session -t mc-server 2>/dev/null || true'";
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s mc-server ./run.sh";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t mc-server 'stop' C-m";
        TimeoutStopSec = 120;
        Restart = "always";
      };
    };
  };
}
