{
  pkgs,
  inputs,
  ...
}: {
  systemd.services = {
    hello-neo-journautics = {
      description = "NeoForge Minecraft Server (Temurin 21) in Tmux";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "forking";
        User = "service";
        Group = "users";
        WorkingDirectory = "/home/service/HelloNeoJournautics";
        path = [
          pkgs.tmux
          pkgs.temurin-bin-21
          pkgs.bash
          pkgs.coreutils
        ];
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s mc-server ./run.sh";
        ExecStop = "${pkgs.tmux}/bin/tmux send-keys -t mc-server 'stop' C-m";
        TimeoutStopSec = 120;
        Restart = "always";
      };
    };
  };
}
