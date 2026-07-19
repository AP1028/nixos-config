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

      shift
      COMMAND="$*"
      TRUNCATED=$(echo "$COMMAND" | head -c 80)
      [ "$TRUNCATED" != "$COMMAND" ] && TRUNCATED="$TRUNCATED..."

      LOCKFILE="${lockdir}/$UID"
      CMDFIFO="${lockdir}/$UID.cmd"
      OUTFIFO="${lockdir}/$UID.out"

      if [ -f "$LOCKFILE" ]; then
        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKPID" ] && [ -d "/proc/$LOCKPID" ]; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            if [ -p "$CMDFIFO" ] && [ -p "$OUTFIFO" ]; then
              >&2 printf '[sudo-env] daemon PID %s | %s\n' "$LOCKPID" "$TRUNCATED"
              printf '%s\n' "$(printf '%s' "$COMMAND" | base64 -w0)" > "$CMDFIFO"
              cat "$OUTFIFO"
              exit 0
            fi
          fi
        fi
      fi

      export SUDO_ASKPASS="${askpassScript}"

      >&2 printf '[sudo-env] kdialog | %s\n' "$TRUNCATED"
      exec sudo --preserve-env -A -p "[sudo-env] $TRUNCATED" sh -c "$COMMAND"
    '')

    (pkgs.writeShellScriptBin "sudo-lock" ''
      # set -e disabled: daemon must survive any command failure
      # Only exit on explicit cleanup signal

      if [ "$(id -u)" -ne 0 ]; then
        echo "[sudo-lock] not root, re-invoking via sudo..." >&2
        exec sudo "$0" "$@"
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
        if [ -n "$LOCKPID" ] && [ -d "/proc/$LOCKPID" ]; then
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
        if [ -n "$LOCKPID" ] && [ -d "/proc/$LOCKPID" ]; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            echo "sudo-lock: already active (PID $LOCKPID)." >&2
            exit 1
          fi
        fi
      fi

      rm -f "$CMDFIFO" "$OUTFIFO"
      mkfifo "$CMDFIFO" 2>/dev/null || { echo "sudo-lock: failed to create FIFO" >&2; exit 1; }
      mkfifo "$OUTFIFO" 2>/dev/null || { echo "sudo-lock: failed to create FIFO" >&2; exit 1; }
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

      # Open FIFO read-write so we can poll with timeout
      exec 3<> "$CMDFIFO"

      echo "sudo-lock active for $SUDO_USER (PID $$). Press Ctrl+C to release."

      while true; do
        if read -t 5 -u 3 encoded 2>/dev/null; then
          [ -z "$encoded" ] && continue
          CMD_TAIL=$(printf '%s' "$encoded" | base64 -d 2>/dev/null | head -c 80)
          echo "[sudo-lock] exec: $CMD_TAIL"
          printf '%s' "$encoded" | base64 -d 2>/dev/null | sh > "$OUTFIFO" 2>&1 || true
          echo "[sudo-lock] done"
        fi
        if [ ! -e /proc/$$/fd/3 ]; then
          echo "[sudo-lock] fd 3 lost, reopening..." >&2
          exec 3<> "$CMDFIFO"
        fi
        sudo -u "$SUDO_USER" -v 2>/dev/null || true
      done
    '')
  ];
}
