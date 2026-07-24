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
        Type = "oneshot";
        RemainAfterExit = true;
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/HelloNeoJournautics";
        ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.tmux}/bin/tmux kill-session -t mc-server 2>/dev/null || true'";
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s mc-server '${pkgs.bash}/bin/bash -c \"while true; do ./run.sh; sleep 5; done\"'";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t mc-server 'stop' C-m";
        TimeoutStopSec = 120;
      };
    };
  };
}
