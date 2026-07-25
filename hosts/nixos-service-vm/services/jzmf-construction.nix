{ pkgs, inputs, ... }:
in {
  systemd.services.jzmf-construction = {
    description = "jzmf-construction Minecraft Server (Temurin 21) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.screen
      pkgs.temurin-bin-21
    ];
    serviceConfig = {
      Type = "simple";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-construction";
      ExecStart = "${pkgs.screen}/bin/screen -DmS jzmf-construction ./run.sh";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff \"stop\"\\015'";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
