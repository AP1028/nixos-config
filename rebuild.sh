#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script with sudo. It handles sudo internally where needed." >&2
  exit 1
fi

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:-}"

# Symlink /etc/nixos → this config directory (standard NixOS convention)
if [ "$(readlink -f /etc/nixos 2>/dev/null)" != "$CONFIG_DIR" ]; then
  if [ -e /etc/nixos ] || [ -L /etc/nixos ]; then
    echo "Backing up existing /etc/nixos to /etc/nixos-bak..."
    sudo mv /etc/nixos /etc/nixos-bak
  fi
  echo "Linking /etc/nixos → $CONFIG_DIR"
  sudo ln -s "$CONFIG_DIR" /etc/nixos
fi

declare -A HOSTNAME_MAP=(
  ["asusg16"]="asusg16"
  ["nixos-service-vm"]="nixos-service-vm"
  ["nixos-git-vm"]="nixos-git-vm"
  ["macbook"]="macbook"
)

AVAILABLE_HOSTS=(asusg16 nixos-service-vm nixos-git-vm macbook)

if [ -z "$HOST" ]; then
  CURRENT_HOSTNAME="$(hostname)"
  if [ -n "${HOSTNAME_MAP[$CURRENT_HOSTNAME]:-}" ]; then
    HOST="${HOSTNAME_MAP[$CURRENT_HOSTNAME]}"
    echo "Auto-detected host: $HOST (from hostname: $CURRENT_HOSTNAME)"
  else
    echo "Could not auto-detect host from hostname: $CURRENT_HOSTNAME"
    echo ""
    echo "Select a host to rebuild:"
    for i in "${!AVAILABLE_HOSTS[@]}"; do
      echo "  $((i+1))) ${AVAILABLE_HOSTS[$i]}"
    done
    read -rp "Enter number (1-${#AVAILABLE_HOSTS[@]}): " choice
    if [[ "$choice" =~ ^[1-4]$ ]]; then
      HOST="${AVAILABLE_HOSTS[$((choice-1))]}"
    else
      echo "Invalid selection."
      exit 1
    fi
  fi
fi

# First run: create local.nix with the main username
if [ ! -f "$CONFIG_DIR/local.nix" ]; then
  DEFAULT_USER="$(whoami)"
  echo ""
  echo "First time setup: configure the main user for this machine."
  read -rp "Username [${DEFAULT_USER}]: " MAIN_USER
  MAIN_USER="${MAIN_USER:-$DEFAULT_USER}"
  cat > "$CONFIG_DIR/local.nix" <<EOF
{ username = "$MAIN_USER"; configDir = "$CONFIG_DIR"; }
EOF
  echo "Created local.nix with username: $MAIN_USER, configDir: $CONFIG_DIR"
fi

cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }

# Tell git to ignore local changes to local.nix (keeps template tracked but personal values local)
git update-index --skip-worktree local.nix 2>/dev/null || true

echo "Pulling latest changes..."
git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."

echo "Staging files..."
git add --all

if git diff --cached --quiet; then
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
sudo nixos-rebuild switch --impure --flake "$CONFIG_DIR#$HOST"
