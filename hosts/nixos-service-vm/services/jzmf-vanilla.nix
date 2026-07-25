{ pkgs, inputs, ... }: {
  systemd.services.jzmf-vanilla = {
    description = "jzmf-vanilla Minecraft Server (Temurin 25) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.temurin-bin-25
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-vanilla";
      ExecStart = "screen -DmS jzmf-vanilla ./run.sh";
      ExecStop = "screen -p 0 -S jzmf-vanilla -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
