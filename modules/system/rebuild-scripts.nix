{ host }:

{ config, pkgs, ... }: let
  configDir = config.local.configDir;
  username = config.local.username;

  # Two execution paths so the scripts work whether invoked directly, via sudo,
  # or via sudo-env:
  #   as_user  — run "normal user" commands (git, nix flake update) as the real
  #              user even when the script itself is running as root.
  #   run_root — run the privileged rebuild directly when already root, via
  #              sudo otherwise.
  helpers = ''
    CONFIG_DIR="${configDir}"
    MAIN_USER="${username}"
    if [ "$(id -u)" -eq 0 ]; then
      if [ -n "''${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        MAIN_USER="$SUDO_USER"
      fi
      as_user() { sudo -u "$MAIN_USER" -- "$@"; }
      run_root() { "$@"; }
    else
      as_user() { "$@"; }
      run_root() { sudo "$@"; }
    fi
  '';
in {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "nixos-switch" ''
      set -euo pipefail
      ${helpers}
      as_user git config --global --add safe.directory "$CONFIG_DIR" 2>/dev/null || true
      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }
      echo "Pulling latest changes..."
      as_user git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."
      echo "Staging files..."
      as_user git add --all
      if as_user git diff --cached --quiet; then
        echo "No changes to commit."
      else
        COMMIT_MSG="Auto-commit from rebuild (${host}): $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Committing changes: $COMMIT_MSG"
        as_user git commit -m "$COMMIT_MSG"
        echo "Pushing to remote..."
        if ! as_user git push; then
          echo -e "\n\e[33mWARNING: Git push failed! Local changes are saved. Continuing with the rebuild...\e[0m\n"
        else
          echo "Push successful."
        fi
      fi
      echo "Starting NixOS rebuild for ${host}..."
      run_root nixos-rebuild switch --impure --flake "$CONFIG_DIR#${host}"
    '')

    (pkgs.writeShellScriptBin "nixos-update-flake" ''
      set -euo pipefail
      ${helpers}
      cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }
      echo "Pulling latest changes..."
      as_user git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."
      echo "Updating flake inputs..."
      as_user nix flake update
      echo "Rebuilding..."
      exec nixos-switch
    '')
  ];
}
