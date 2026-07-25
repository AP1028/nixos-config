{
  pkgs,
  ...
}: {
  systemd.services.jzmf-construction-backup = {
    description = "Daily world backup for jzmf-construction";
    after = ["jzmf-construction.service"];
    path = [
      pkgs.screen
      pkgs.zip
      pkgs.bash
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-construction";
    };
    script = ''
      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "tellraw @a {"text":"[Backup] Starting world backup...","color":"gold"}\015'
      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "save-all"\015'
      sleep 10
      ts=$(date +%Y-%m-%d_%H-%M-%S)
      zip -r "/home/service/jzmf-construction/world-backup-''${ts}.zip" world
      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "tellraw @a {"text":"[Backup] World backup complete.","color":"green"}\015'
      ls -1 world-backup-*.zip | sort | head -n -15 | xargs -r rm --
    '';
  };

  systemd.timers.jzmf-construction-backup = {
    description = "Timer for jzmf-construction daily world backup";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };
}
