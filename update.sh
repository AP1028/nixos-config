#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:-}"

cd "$CONFIG_DIR" || { echo "Error: Could not navigate to $CONFIG_DIR"; exit 1; }

echo "Pulling latest changes..."
git pull --ff-only || echo "Warning: git pull failed, continuing with local changes..."

echo "Updating flake inputs..."
nix flake update

echo "Rebuilding..."
exec ./rebuild.sh "$HOST"
