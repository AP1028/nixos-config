{
  config,
  lib,
  pkgs,
  ...
}: let
  kdialogBin = "${pkgs.kdePackages.kdialog}/bin/kdialog";

  askpassScript = pkgs.writeShellScript "desktop-askpass" ''
    if [ -x "${kdialogBin}" ]; then
      ${kdialogBin} --password "$1" 2>/dev/null
    else
      echo "Error: Graphical pinentry tool not found." >&2
      exit 1
    fi
  '';

  lockdir = "/run/sudo-env-lock";
in
{
  systemd.tmpfiles.rules = [
    "d ${lockdir} 0755 root root -"
  ];

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "sudo-env" ''
      set -e

      if [ "$1" != "-c" ] || [ -z "$2" ]; then
        echo "Usage: sudo-env -c 'your-escalated-command'" >&2
        exit 1
      fi

      COMMAND="$2"
      TRUNCATED=$(echo "$COMMAND" | head -c 80)
      [ "$TRUNCATED" != "$COMMAND" ] && TRUNCATED="$TRUNCATED..."

      LOCKFILE="${lockdir}/$UID"
      CMDFIFO="${lockdir}/$UID.cmd"
      OUTFIFO="${lockdir}/$UID.out"

      if [ -f "$LOCKFILE" ]; then
        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKPID" ] && kill -0 "$LOCKPID" 2>/dev/null; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            if [ -p "$CMDFIFO" ] && [ -p "$OUTFIFO" ]; then
              echo "[sudo-env] lock active (PID $LOCKPID), delegating..." >&2
              printf '%s\n' "$(printf '%s' "$COMMAND" | base64 -w0)" > "$CMDFIFO"
              cat "$OUTFIFO"
              exit 0
            fi
          fi
        fi
      fi

      export SUDO_ASKPASS="${askpassScript}"

      exec sudo --preserve-env -A -p "[sudo-env] Password to run: $TRUNCATED" sh -c "$COMMAND"
    '')

    (pkgs.writeShellScriptBin "sudo-lock" ''
      set -e

      if [ "$(id -u)" -ne 0 ]; then
        echo "sudo-lock must be run as root." >&2
        echo "Usage: sudo-env -c 'sudo-lock'" >&2
        echo "       sudo-env -c 'sudo-lock --clean'" >&2
        echo "Start in tmux/screen to keep it alive across sessions." >&2
        exit 1
      fi

      if [ -z "$SUDO_USER" ]; then
        echo "sudo-lock: SUDO_USER not set. Run via sudo-env." >&2
        exit 1
      fi

      # Auto-detach: if not a terminal, re-launch with nohup to survive parent
      if [ ! -t 0 ] && [ "$1" != "--fg" ]; then
        nohup "$0" --fg "$@" < /dev/null >> /tmp/sudo-lock.log 2>&1 &
        echo "sudo-lock: detached (PID $!). Output -> /tmp/sudo-lock.log"
        exit 0
      fi

      LOCKFILE="${lockdir}/$SUDO_UID"
      CMDFIFO="${lockdir}/$SUDO_UID.cmd"
      OUTFIFO="${lockdir}/$SUDO_UID.out"

      if [ "$1" = "--clean" ]; then
        if [ ! -f "$LOCKFILE" ]; then
          echo "sudo-lock: no lock found for $SUDO_USER."
          exit 0
        fi
        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKPID" ] && kill -0 "$LOCKPID" 2>/dev/null; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            echo "sudo-lock: lock is active (PID $LOCKPID). Kill it first or press Ctrl+C in its terminal." >&2
            exit 1
          fi
        fi
        rm -f "$LOCKFILE" "$CMDFIFO" "$OUTFIFO"
        echo "sudo-lock: cleaned stale lock for $SUDO_USER."
        exit 0
      fi

      mkdir -p "$(dirname "$LOCKFILE")"

      if [ -f "$LOCKFILE" ]; then
        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKPID" ] && kill -0 "$LOCKPID" 2>/dev/null; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            echo "sudo-lock: already active (PID $LOCKPID)." >&2
            exit 1
          fi
        fi
      fi

      rm -f "$CMDFIFO" "$OUTFIFO"
      mkfifo "$CMDFIFO" 2>/dev/null
      mkfifo "$OUTFIFO" 2>/dev/null
      chmod 622 "$CMDFIFO"
      chmod 644 "$OUTFIFO"

      echo "$$" > "$LOCKFILE"

      cleanup() {
        exec 3>&- 2>/dev/null || true
        if [ -f "$LOCKFILE" ] && [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ]; then
          rm -f "$LOCKFILE"
        fi
        rm -f "$CMDFIFO" "$OUTFIFO"
        echo ""
        echo "sudo-lock released."
        exit 0
      }
      trap cleanup INT TERM HUP

      # Open FIFO read-write so we can poll with timeout (no separate executor needed)
      exec 3<> "$CMDFIFO"

      echo "sudo-lock active for $SUDO_USER (PID $$). Press Ctrl+C to release."

      while true; do
        if read -t 5 -u 3 encoded; then
          [ -z "$encoded" ] && continue
          CMD_TAIL=$(printf '%s' "$encoded" | base64 -d | head -c 80)
          echo "[sudo-lock] exec: $CMD_TAIL"
          printf '%s' "$encoded" | base64 -d | sh > "$OUTFIFO" 2>&1
          echo "[sudo-lock] done"
        fi
        sudo -u "$SUDO_USER" -v 2>/dev/null || true
      done
    '')
  ];
}
