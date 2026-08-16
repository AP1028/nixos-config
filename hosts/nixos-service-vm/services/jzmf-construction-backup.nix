{pkgs, ...}: {
  systemd.services.jzmf-construction-backup = {
    description = "Daily world backup for jzmf-construction (scp to file-vm)";
    after = ["jzmf-construction.service"];
    path = [
      pkgs.screen
      pkgs.zip
      pkgs.bash
      pkgs.coreutils
      pkgs.openssh
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "service";
      Group = "users";
      WorkingDirectory = "/home/service/jzmf-construction";
    };
    script = ''
      set -euo pipefail

      # Passwordless scp/ssh to the file VM as tianyixia. The private key is
      # generated on first use; its public key must be present in
      # tianyixia@nixos-file-vm:~/.ssh/authorized_keys.
      install -d -m 700 /home/service/.ssh
      if [ ! -f /home/service/.ssh/id_ed25519 ]; then
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /home/service/.ssh/id_ed25519
      fi
      ssh_opts=(
        -i /home/service/.ssh/id_ed25519
        -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
      )

      remote_dir=/hdd/Public/mc-backup/jzmf-construction
      remote_host=tianyixia@192.168.3.104

      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "tellraw @a {"text":"[Backup] Starting world backup...","color":"gold"}\015'
      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "save-all"\015'
      sleep 10

      ts=$(date +%Y-%m-%d_%H-%M-%S)
      tmpdir=$(mktemp -d /tmp/jzmf-construction-backup.XXXXXX)
      trap 'rm -rf "''${tmpdir}"' EXIT

      zip -r "''${tmpdir}/backup.zip" world
      ${pkgs.openssh}/bin/ssh "''${ssh_opts[@]}" "''${remote_host}" "mkdir -p ''${remote_dir}"
      ${pkgs.openssh}/bin/scp "''${ssh_opts[@]}" "''${tmpdir}/backup.zip" "''${remote_host}:''${remote_dir}/''${ts}.zip"

      # Keep the newest 15 backups on the file VM.
      ${pkgs.openssh}/bin/ssh "''${ssh_opts[@]}" "''${remote_host}" "cd ''${remote_dir} && ls -1 *.zip | sort | head -n -15 | xargs -r rm --"

      ${pkgs.screen}/bin/screen -p 0 -S jzmf-construction -X eval 'stuff "tellraw @a {"text":"[Backup] World backup complete.","color":"green"}\015'
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
