#!/bin/sh
set -e

NITROX_HOME="${NITROX_HOME:-$HOME/.local/share/nitrox}"
mkdir -p "$NITROX_HOME"

# Sync from read-only nix store to writable location, preserving user configs
@rsync@ -a --ignore-existing @nitroxSrc@/ "$NITROX_HOME/"

cd "$NITROX_HOME"
export DOTNET_ROOT=@dotnetRoot@
exec @nitroxSrc@/Nitrox.Launcher "$@"
