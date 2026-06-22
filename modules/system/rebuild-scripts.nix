{ host }:

{ config, pkgs, ... }: let
  configDir = config.local.configDir;
in {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nixos-rebuild" ''
      set -euo pipefail

      HOST="''${1:-${host}}"
      CONFIG_DIR="${configDir}"
      KNOWN_HOSTS="${knownHosts}"

      if ! echo "$KNOWN_HOSTS" | grep -qw "$HOST"; then
        echo "Error: unknown host '$HOST'" >&2
        echo "Available hosts: $KNOWN_HOSTS" >&2
        exit 1
      fi

      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }

      echo "Staging files..."
      git add --all

      if git diff-index --quiet HEAD --; then
        echo "No changes to commit."
      else
        COMMIT_MSG="Auto-commit from rebuild ($HOST): $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Committing changes: $COMMIT_MSG"
        git commit -m "$COMMIT_MSG"

        echo "Pushing to remote..."
        if ! git push; then
          echo -e "\n\e[33mWARNING: Git push failed! Local changes are saved. Continuing with the rebuild...\e[0m\n"
        else
          echo "Push successful."
        fi
      fi

      echo "Starting NixOS rebuild for $HOST..."
      sudo nixos-rebuild switch --flake "$CONFIG_DIR#$HOST"
    '')

    (pkgs.writeShellScriptBin "nixos-update" ''
      set -euo pipefail

      HOST="''${1:-${host}}"
      CONFIG_DIR="${configDir}"
      KNOWN_HOSTS="${knownHosts}"

      if ! echo "$KNOWN_HOSTS" | grep -qw "$HOST"; then
        echo "Error: unknown host '$HOST'" >&2
        echo "Available hosts: $KNOWN_HOSTS" >&2
        exit 1
      fi

      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }

      echo "Updating flake inputs..."
      nix flake update
      echo "Rebuilding..."
      exec nixos-rebuild "$HOST"
    '')
  ];
}
