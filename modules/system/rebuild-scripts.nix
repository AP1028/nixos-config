{ host }:

{ config, pkgs, ... }: let
  configDir = config.local.configDir;
in {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nixos-switch" ''
      set -euo pipefail
      if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this script with sudo. It handles sudo internally where needed." >&2
        exit 1
      fi
      CONFIG_DIR="${configDir}"
      git config --global --add safe.directory "$CONFIG_DIR" 2>/dev/null || true
      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }
      echo "Pulling latest changes..."
      git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."
      echo "Staging files..."
      git add --all
      if git diff --cached --quiet; then
        echo "No changes to commit."
      else
        COMMIT_MSG="Auto-commit from rebuild (${host}): $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Committing changes: $COMMIT_MSG"
        git commit -m "$COMMIT_MSG"
        echo "Pushing to remote..."
        if ! git push; then
          echo -e "\n\e[33mWARNING: Git push failed! Local changes are saved. Continuing with the rebuild...\e[0m\n"
        else
          echo "Push successful."
        fi
      fi
      echo "Starting NixOS rebuild for ${host}..."
      sudo nixos-rebuild switch --impure --flake "$CONFIG_DIR#${host}"
    '')

    (pkgs.writeShellScriptBin "nixos-update-flake" ''
      set -euo pipefail
      if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this script with sudo. It handles sudo internally where needed." >&2
        exit 1
      fi
      CONFIG_DIR="${configDir}"
      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }
      echo "Pulling latest changes..."
      git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."
      echo "Updating flake inputs..."
      nix flake update
      echo "Rebuilding..."
      exec nixos-switch
    '')
  ];
}
