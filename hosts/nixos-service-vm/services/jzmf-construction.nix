{
  pkgs,
  inputs,
  ...
}: {
  systemd.services = {
    jzmf-construction = {
      description = "jzmf-construction Minecraft Server (Temurin 21) in Tmux";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.tmux
        pkgs.temurin-bin-21
        pkgs.bash
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "forking";
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/jzmf-construction";
        ExecStartPre = "${pkgs.bash}/bin/bash -c '${pkgs.tmux}/bin/tmux kill-session -t jzmf-construction 2>/dev/null || true'";
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s jzmf-construction ./run.sh";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t jzmf-construction 'stop' C-m";
        TimeoutStopSec = 120;
        Restart = "always";
      };
    };
  };
}
