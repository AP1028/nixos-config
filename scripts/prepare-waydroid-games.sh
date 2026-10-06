#!/usr/bin/env bash
# Prepare a KiriKiri2 game library for Kirikiroid2 under Waydroid.
#
# Three things have to be true for a game copied in from the host to start:
#
#   1. every name is lowercase -- the engine lowercases the paths it opens
#      (Windows-era habit) and Waydroid's /data is a plain, case-sensitive ext4
#      image, so `[KR] .../data.xp3` fails with "Cannot open storage
#      .../[kr] .../data.xp3" and the app dies with an uncaught TJSError;
#   2. the files look Android-created -- owner = the app's uid, group =
#      media_rw (1023), group-writable, setgid on directories -- otherwise
#      MediaProvider's FUSE daemon cannot write them and in-game saves fail
#      ("saveSystemVariables失敗 : rename failed: .../savedata//datasc.ksc");
#   3. the host user keeps access, so files can be copied in without sudo --
#      done with an ACL (see waydroid-sdcard-access.service).
#
# Usage:
#   sudo scripts/prepare-waydroid-games.sh                 # /sdcard/krkr2, package org.github.krkr2
#   sudo scripts/prepare-waydroid-games.sh ~/.local/share/waydroid/data/media/0/krkr2
#   sudo scripts/prepare-waydroid-games.sh --package org.tv.kirikiri2_free <dir>
#   sudo scripts/prepare-waydroid-games.sh --no-lowercase <dir>   # case is already fine

set -euo pipefail

DATA="${WAYDROID_DATA:-/home/$SUDO_USER/.local/share/waydroid/data}"
PKG=org.github.krkr2
LOWERCASE=1
[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --package) PKG="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --no-lowercase) LOWERCASE=0; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
DIR="${1:-$DATA/media/0/krkr2}"
[ -d "$DIR" ] || { echo "$DIR: not a directory" >&2; exit 2; }

# The app's uid lives in /data; ask the container for it (falls back to the
# usual first-install value).
UID_APP=$(waydroid shell -- cmd package list packages -U 2>/dev/null \
          | awk -v p="$PKG" '$0 ~ p {for (i=1;i<=NF;i++) if ($i ~ /^uid:/) {gsub("uid:","",$i); print $i}}' | head -1)
UID_APP="${UID_APP:-10139}"
echo "app=$PKG uid=$UID_APP dir=$DIR"

if [ "$LOWERCASE" = 1 ]; then
  repo_dir=$(cd "$(dirname "$0")" && pwd)
  python3 "$repo_dir/fix-krkr2-lowercase.py" --apply --recursive "$DIR" | tail -3
fi

# Android-native ownership: app owns it, media_rw may write it (FUSE daemon),
# directories are setgid so newly created files inherit the media_rw group.
chown -R "$UID_APP:1023" "$DIR"
chmod -R u+rwX,g+rwX "$DIR"
find "$DIR" -type d -exec chmod g+s {} +

# Keep the host user able to copy more files in.
HOST_USER="${SUDO_USER:-$(id -un 1000)}"
setfacl -R -m "u:$HOST_USER:rwx" "$DIR"
setfacl -R -d -m "u:$HOST_USER:rwx" "$DIR" 2>/dev/null || true
echo "prepared: $DIR  (lowercase=$LOWERCASE, owner=$UID_APP:1023, host acl for $HOST_USER)"
