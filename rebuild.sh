#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script with sudo. It handles sudo internally where needed." >&2
  exit 1
fi

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST=""
AUTO_REPLACE=0
AUTO_ABORT=0

usage() {
  echo "Usage: $0 [--host=HOST | HOST] [--replace-hardware | --abort-hardware]" >&2
  echo "  --host=HOST         Rebuild the given host (no auto-detect / selection prompt)" >&2
  echo "  --replace-hardware  Auto-choose 'replace' when /etc/nixos hardware config differs" >&2
  echo "  --abort-hardware    Auto-choose 'abort' when /etc/nixos hardware config differs" >&2
  echo "  (no flags)          Interactive prompts as before" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host=*)
      if [ -n "$HOST" ]; then
        echo "Host specified twice: '$HOST' and '${1#*=}'" >&2
        exit 1
      fi
      HOST="${1#*=}"
      ;;
    --host)
      shift
      if [ -n "$HOST" ]; then
        echo "Host specified twice: '$HOST' and '${1:-}'" >&2
        exit 1
      fi
      HOST="${1:-}"
      ;;
    --replace-hardware) AUTO_REPLACE=1 ;;
    --abort-hardware) AUTO_ABORT=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "$HOST" ]; then
        echo "Host specified twice: '$HOST' and '$1'" >&2
        exit 1
      fi
      HOST="$1"
      ;;
  esac
  shift
done

if [ "$AUTO_REPLACE" -eq 1 ] && [ "$AUTO_ABORT" -eq 1 ]; then
  echo "Error: --replace-hardware and --abort-hardware are mutually exclusive." >&2
  exit 1
fi

# Discover machines from the hosts/ directory (each host is hosts/<name>/default.nix)
AVAILABLE_HOSTS=()
for d in "$CONFIG_DIR"/hosts/*/; do
  [ -f "${d}default.nix" ] && AVAILABLE_HOSTS+=("$(basename "$d")")
done
if [ "${#AVAILABLE_HOSTS[@]}" -eq 0 ]; then
  echo "No hosts found under $CONFIG_DIR/hosts/" >&2
  exit 1
fi

if [ -z "$HOST" ]; then
  CURRENT_HOSTNAME="$(hostname)"
  if [[ " ${AVAILABLE_HOSTS[*]} " == *" $CURRENT_HOSTNAME "* ]]; then
    HOST="$CURRENT_HOSTNAME"
    echo "Auto-detected host: $HOST (from hostname: $CURRENT_HOSTNAME)"
  else
    echo "Could not auto-detect host from hostname: $CURRENT_HOSTNAME"
    echo ""
    echo "Select a host to rebuild:"
    for i in "${!AVAILABLE_HOSTS[@]}"; do
      echo "  $((i+1))) ${AVAILABLE_HOSTS[$i]}"
    done
    read -rp "Enter number (1-${#AVAILABLE_HOSTS[@]}): " choice
    if [[ "$choice" =~ ^[1-${#AVAILABLE_HOSTS[@]}]$ ]]; then
      HOST="${AVAILABLE_HOSTS[$((choice-1))]}"
    else
      echo "Invalid selection."
      exit 1
    fi
  fi
fi

# --- Hardware-configuration consistency check (quick VM deployment) ---
# On a freshly installed machine, /etc/nixos is a real directory holding the
# hardware-configuration.nix generated at install time. If it differs from the
# host's tracked copy, offer to sync it into the repo (and publish via git) or
# abort. When /etc/nixos already points at this repo (e.g. this machine), the
# files are the same by construction and this check is skipped.
if [ -e /etc/nixos/hardware-configuration.nix ] &&
   [ "$(readlink -f /etc/nixos 2>/dev/null)" != "$CONFIG_DIR" ]; then
  REPO_HW="$CONFIG_DIR/hosts/$HOST/hardware-configuration.nix"
  if [ -f "$REPO_HW" ] && cmp -s /etc/nixos/hardware-configuration.nix "$REPO_HW"; then
    echo "hardware-configuration.nix for '$HOST' matches /etc/nixos — continuing."
  else
    echo ""
    echo "hardware-configuration.nix mismatch for host '$HOST':"
    echo "  /etc/nixos/hardware-configuration.nix  (generated at install)"
    echo "  $REPO_HW  (tracked in this repo)"
    echo ""
    echo "1) Replace the tracked hardware-configuration.nix with the /etc/nixos one"
    echo "   (git pull first, then commit & push, then rebuild)"
    echo "2) Abort"
    if [ "$AUTO_REPLACE" -eq 1 ]; then
      hw_choice=1
      echo "(auto-selected: 1 — replace hardware configuration)"
    elif [ "$AUTO_ABORT" -eq 1 ]; then
      hw_choice=2
      echo "(auto-selected: 2 — abort)"
    else
      read -rp "Choose (1-2): " hw_choice
    fi
    case "$hw_choice" in
      1)
        # Sync the repo with upstream BEFORE touching the file, so the
        # replacement is committed on top of the latest remote state.
        if command -v git >/dev/null 2>&1; then
          if (cd "$CONFIG_DIR" && timeout 30 git pull --ff-only) >/dev/null 2>&1; then
            echo "git pull: OK"
          else
            echo "warning: git pull skipped (unavailable or timed out)"
          fi
        else
          echo "warning: git not found — hardware-configuration.nix will be updated locally only"
        fi

        cp /etc/nixos/hardware-configuration.nix "$REPO_HW"
        echo "Replaced: $REPO_HW"

        if command -v git >/dev/null 2>&1; then
          if (cd "$CONFIG_DIR" && git add "hosts/$HOST/hardware-configuration.nix" &&
              git commit -m "Update hardware-configuration.nix for $HOST from /etc/nixos install") >/dev/null 2>&1; then
            echo "git commit: OK"
          else
            echo "warning: git commit skipped (nothing to commit or git error)"
          fi
          if (cd "$CONFIG_DIR" && timeout 30 git push) >/dev/null 2>&1; then
            echo "git push: OK"
          else
            echo "warning: git push skipped (unavailable or timed out)"
          fi
        fi
        ;;
      2)
        echo "Aborted. Re-run once /etc/nixos/hardware-configuration.nix is sorted out." >&2
        exit 1
        ;;
      *)
        echo "Invalid selection."
        exit 1
        ;;
    esac
  fi
fi

# Symlink /etc/nixos → this config directory (standard NixOS convention)
if [ "$(readlink -f /etc/nixos 2>/dev/null)" != "$CONFIG_DIR" ]; then
  if [ -e /etc/nixos ] || [ -L /etc/nixos ]; then
    echo "Backing up existing /etc/nixos to /etc/nixos-bak..."
    sudo mv /etc/nixos /etc/nixos-bak
  fi
  echo "Linking /etc/nixos → $CONFIG_DIR"
  sudo ln -s "$CONFIG_DIR" /etc/nixos
fi

# First run: create local.nix from the tracked template
if [ ! -f "$CONFIG_DIR/local.nix" ]; then
  DEFAULT_USER="$(whoami)"
  echo ""
  echo "First time setup: configure the main user for this machine."
  read -rp "Username [${DEFAULT_USER}]: " MAIN_USER
  MAIN_USER="${MAIN_USER:-$DEFAULT_USER}"
  sed -e "s|main-user|$MAIN_USER|g" \
      -e "s|Main User|$MAIN_USER|g" \
      -e "s|/home/main-user/nixos-config|$CONFIG_DIR|" \
      "$CONFIG_DIR/local.nix.template" > "$CONFIG_DIR/local.nix"
  echo "Created local.nix with username: $MAIN_USER, configDir: $CONFIG_DIR"
fi

cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }

echo "Starting NixOS rebuild for $HOST..."
# --accept-flake-config: don't prompt to trust the flake-declared nixConfig
# (nixos-apple-silicon.cachix.org substituter + public key) on first build.
sudo nixos-rebuild switch --impure --accept-flake-config --flake "$CONFIG_DIR#$HOST"
