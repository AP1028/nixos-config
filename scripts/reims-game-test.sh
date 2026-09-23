#!/usr/bin/env bash
# One automated game-test cycle on the reims-vgpu macOS guest.
#
# Boots the guest, launches a Steam title over SSH, captures the host's Reims
# vGPU window (spectacle) and the guest's own composite (screencapture), dumps a
# bounded refusal census from the device fail log, and shuts the guest down.
# Everything except the two screenshots is SSH; the host capture is the only
# step no guest-side tool can do, because the guest's frames are presented by
# the device's own winit window (`-display none` means there is no QEMU console
# surface to `screendump`).
#
#   scripts/reims-game-test.sh <qemu-bin> <tag> [appid]
#
# App ids seen in this guest's library: Star Birds 2719750, Easy Red 2 1324780,
# Universe Sandbox 230290. Star Birds needs no interaction; Easy Red 2 needs a
# space key at the menu, which is what `guest_key` below is for.
set -uo pipefail

QEMU_BIN="${1:?usage: reims-game-test.sh <qemu-bin> <tag> [appid]}"
TAG="${2:?usage: reims-game-test.sh <qemu-bin> <tag> [appid]}"
APPID="${3:-2719750}"
SHOTS="/tmp/opencode/shots"
GUEST="macos-vm"
GUEST_PW=12345678

ssh_guest() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$GUEST" "$@"; }

# Send a key chord to the guest through QEMU's own USB keyboard (monitor
# `sendkey`), which needs no guest permissions and no window focus rules.
# Kept here because it is the fallback for menu interaction the SSH-side
# AppleScript path (`osascript -e 'tell application "System Events" to key code 49'`)
# cannot do without granting Accessibility.
qmp_key() {
  local sock key="$1"
  sock="$(ls -t "$HOME"/reims-vgpu/vm/disks/run/qmp-*.sock 2>/dev/null | head -1)"
  [ -n "$sock" ] || { echo "no qmp socket"; return 1; }
  python3 - "$sock" "$key" <<'PY'
import json, socket, sys
sock, key = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock)
f = s.makefile("rw", buffering=1)
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.readline()
f.write(json.dumps({"execute": "send-key", "arguments": {"keys": [{"type": "qcode", "data": key}]}}) + "\n")
print(f.readline().strip())
PY
}

mkdir -p "$SHOTS"
echo "== booting ($TAG)"
/tmp/opencode/run-game.sh "$QEMU_BIN" "$TAG" || exit 1

echo "== launching appid $APPID"
ssh_guest "nohup /Applications/Steam.app/Contents/MacOS/steam_osx 'steam://rungameid/$APPID' >/tmp/steam-launch.log 2>&1 &" >/dev/null 2>&1

echo "== waiting for the game process"
for _ in $(seq 1 24); do
  if ssh_guest 'ps -Ao comm= | grep -iE "Star Birds|Easy Red|Universe Sandbox" | grep -qv grep' >/dev/null 2>&1; then
    echo "   running"; break
  fi
  sleep 10
done
sleep 20   # let the first frames land before the capture

echo "== capturing host window and guest composite"
spectacle -b -n -f -o "$SHOTS/$TAG-host.png" >/dev/null 2>&1
ssh_guest 'screencapture -x /tmp/guest-shot.png' >/dev/null 2>&1
scp -q "$GUEST:/tmp/guest-shot.png" "$SHOTS/$TAG-guest.png" 2>/dev/null
ls -la "$SHOTS/$TAG"-*.png 2>/dev/null

echo "== refusal census (fail log, this boot)"
timeout 300 awk '
/linux_m2v_draw reason=/ { if (match($0, /reason=[A-Za-z_0-9]+/)) r[substr($0,RSTART+7,RLENGTH-7)]++; next }
/rt_resolve reason=/     { if (match($0, /reason=[A-Za-z_0-9]+/)) rt[substr($0,RSTART+7,RLENGTH-7)]++; next }
/blit_fail reason=/      { if (match($0, /reason=[A-Za-z_0-9]+/)) bf[substr($0,RSTART+7,RLENGTH-7)]++; next }
/vk_slab_allocate_memory/ { slab++ }
/vram_pool_reclaim_retry/ { if (match($0, /held_bytes=[0-9]+/)) held=substr($0,RSTART+11,RLENGTH-11) }
END {
  printf "  draw refusals:\n"; for (k in r) printf "  %8d %s\n", r[k], k | "sort -rn | head -8"; close("sort -rn | head -8");
  printf "  rt_resolve:\n";    for (k in rt) printf "  %8d %s\n", rt[k], k | "sort -rn | head -6"; close("sort -rn | head -6");
  printf "  blit_fail:\n";     for (k in bf) printf "  %8d %s\n", bf[k], k | "sort -rn | head -6"; close("sort -rn | head -6");
  printf "  slab allocation failures: %d (last held_bytes=%s)\n", slab, held;
}' /tmp/reims-vgpu-fail.log 2>/dev/null

echo "== shutting the guest down"
ssh_guest "echo $GUEST_PW | sudo -S shutdown -h now" >/dev/null 2>&1
for _ in $(seq 1 30); do pgrep -x qemu-system-x86_64 >/dev/null || break; sleep 4; done
echo "== done ($TAG)"
