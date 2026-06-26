{pkgs ? import <nixpkgs> {}}: let
  # Explicitly extract kdialog from the standard modern KDE package set
  kdialogBin = "${pkgs.kdePackages.kdialog}/bin/kdialog";

  # This is the secure helper script that sudo will call internally to ask for the password
  askpassScript = pkgs.writeShellScript "desktop-askpass" ''
    # Using the store-isolated kdialog package directly
    if [ -x "${kdialogBin}" ]; then
      ${kdialogBin} --password "$1"
    else
      # Tiny backup fallback in case it ever executes outside graphical display context
      echo "Error: Graphical pinentry tool not found." >&2
      exit 1
    fi
  '';
in
  pkgs.writeShellScriptBin "sudo-env" ''
    set -e

    # Ensure correct arguments are passed by the agent
    if [ "$1" != "-c" ] || [ -z "$2" ]; then
      echo "Usage: sudo-env -c 'your-escalated-command'" >&2
      exit 1
    fi

    COMMAND="$2"
    PROMPT_TEXT="⚠️ OpenCode Agent is requesting root privileges to run:

    $COMMAND

    Enter your user password to authorize this action:"

    # Export the secure askpass helper script path
    export SUDO_ASKPASS="${askpassScript}"

    # Flags:
    # -k : Instantly flushes any existing sudo credentials cache (no ticket hijacking)
    # -A : Forces sudo to prompt via the graphical ASKPASS helper instead of terminal TTY
    exec sudo -k -A sh -c "$COMMAND"
  ''
