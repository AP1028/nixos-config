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
in
{
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

      export SUDO_ASKPASS="${askpassScript}"

      exec sudo -k -A -p "[sudo-env] Password to run: $TRUNCATED" sh -c "$COMMAND"
    '')
  ];
}
