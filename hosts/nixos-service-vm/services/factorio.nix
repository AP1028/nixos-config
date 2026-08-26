{ pkgs, inputs, ... }: {
  systemd.services.factorio = {
    description = "Factorio Headless Server (2.0.77) in Screen";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    path = [
      pkgs.screen
      pkgs.bash
    ];
    serviceConfig = {
      Type = "forking";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/factorio";
      ExecStart = "${pkgs.screen}/bin/screen -dmS factorio ./bin/x64/factorio --start-server ./saves/server.zip --server-settings ./config/server-settings.json --port 34197";
      ExecStop = "${pkgs.screen}/bin/screen -p 0 -S factorio -X eval 'stuff \"/shutdown\"\\015'";
      Environment = "TERM=xterm-256color";
      Restart = "always";
      RestartSec = 15;
      TimeoutStopSec = 120;
    };
  };
}
