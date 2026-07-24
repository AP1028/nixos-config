{
  pkgs,
  inputs,
  ...
}: {
  systemd.services = {
    jzmf-vanilla = {
      description = "jzmf-vanilla Minecraft Server (Temurin 25) in Tmux";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.tmux
        pkgs.temurin-bin-25
        pkgs.bash
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/jzmf-vanilla";
        ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.tmux}/bin/tmux kill-session -t jzmf-vanilla 2>/dev/null || true'";
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s jzmf-vanilla '${pkgs.bash}/bin/bash -c \"while true; do ./run.sh; sleep 5; done\"'";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t jzmf-vanilla 'stop' C-m";
        TimeoutStopSec = 120;
      };
    };
  };
}
