{ pkgs, inputs, ... }:
in {
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
      ExecStart = "${pkgs.screen}/bin/screen -DmS jzmf-vanilla ./run.sh";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S jzmf-vanilla -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
