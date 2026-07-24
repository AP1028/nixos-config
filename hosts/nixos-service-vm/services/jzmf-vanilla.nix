{
  pkgs,
  inputs,
  ...
}: {
  systemd.services = {
    jzmf-vanilla = {
      description = "jzmf-vanilla-26.2 Minecraft Server (Temurin 25) in Tmux";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "forking";
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/jzmf-vanilla-26.2";
        path = [
          pkgs.tmux
          pkgs.temurin-bin-25
          pkgs.bash
          pkgs.coreutils
        ];
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s jzmf-vanilla ./run.sh";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t jzmf-vanilla 'stop' C-m";
        TimeoutStopSec = 120;
        Restart = "always";
      };
    };
  };
}
