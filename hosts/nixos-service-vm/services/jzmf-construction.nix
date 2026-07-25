{ pkgs, inputs, ... }: {
  systemd.services.jzmf-construction = {
    description = "jzmf-construction Minecraft Server (Temurin 21) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.temurin-bin-21
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-construction";
      ExecStart = "screen -DmS jzmf-construction ./run.sh";
      ExecStop = "screen -p 0 -S jzmf-construction -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
