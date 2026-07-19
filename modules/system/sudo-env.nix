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

      if [ -f "$LOCKFILE" ]; then
        LOCKPID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKPID" ] && kill -0 "$LOCKPID" 2>/dev/null; then
          if grep -q "^sudo-lock$" "/proc/$LOCKPID/comm" 2>/dev/null; then
            sudo -n --preserve-env sh -c "$COMMAND" 2>/dev/null && exit 0
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
        exit 1
      fi

      if [ -z "$SUDO_USER" ]; then
        echo "sudo-lock: SUDO_USER not set. Run via sudo-env." >&2
        exit 1
      fi

      LOCKFILE="${lockdir}/$SUDO_UID"
      mkdir -p "$(dirname "$LOCKFILE")"
      echo "$$" > "$LOCKFILE"

      cleanup() {
        rm -f "$LOCKFILE"
        echo ""
        echo "sudo-lock released."
        exit 0
      }
      trap cleanup INT TERM HUP

      echo "sudo-lock active for $SUDO_USER. Press Ctrl+C to release."

      while true; do
        sudo -u "$SUDO_USER" -v 2>/dev/null || true
        sleep 25
      done
    '')
  ];
}
