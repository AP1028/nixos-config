#!/usr/bin/env bash
# One iGPU test cycle on the reims-vgpu macOS guest, aimed at the *launch
# transition* rather than a single late frame: boot, burst-capture the device's
# own host window while the title launches, collect the device's present dumps
# and refusal census, then shut the guest down.
#
#   cycle-fresh.sh <qemu-bin> [tag] [appid] [device-env]
#
# The single-shot capture in scripts/reims-game-test.sh answers "what does the
# menu look like"; this answers "what happens on the way there", which is where
# the stale-attachment artifact lived (the launch splash's rows surviving into
# the menu). Host capture, not the guest's: the frames are presented by the
# device's own winit window and `-display none` leaves no console surface.
set -uo pipefail

QEMU_BIN="${1:?usage: cycle-fresh.sh <qemu-bin> [tag] [appid] [device-env]}"
TAG="${2:-fresh}"
APPID="${3:-2719750}"
DEVICE_ENV="${4:-REIMS_VGPU_VK_DEVICE_TYPE=integrated}"
SHOTS=/tmp/opencode/shots
DUMPS=/tmp/opencode/dumps-$TAG
GUEST=macos-vm

ssh_guest() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$GUEST" "$@"; }

rm -rf "$DUMPS"; mkdir -p "$DUMPS" "$SHOTS"

echo "== booting ($TAG, $DEVICE_ENV)"
EXTRA_ENV="$DEVICE_ENV REIMS_VGPU_PRESENT_DUMP=$DUMPS" \
  /tmp/opencode/run-game.sh "$QEMU_BIN" "$TAG" || exit 1

echo "== waiting for the guest's own session (the frames come from its desktop)"
for _ in $(seq 1 60); do
  user="$(ssh_guest 'stat -f%Su /dev/console' 2>/dev/null | tr -d '\r')"
  if [ -n "$user" ] && [ "$user" != "root" ]; then
    echo "   console user $user"
    break
  fi
  sleep 5
done
sleep 15

echo "== burst capturing the host window across the launch"
(
  for i in $(seq -w 1 40); do
    spectacle -b -n -f -o "$SHOTS/$TAG-$i-host.png" >/dev/null 2>&1
    sleep 2
  done
) &
BURST=$!
sleep 3
echo "== launching appid $APPID"
ssh_guest "nohup /Applications/Steam.app/Contents/MacOS/steam_osx 'steam://rungameid/$APPID' >/tmp/steam-launch.log 2>&1 &" >/dev/null 2>&1
for _ in $(seq 1 24); do
  if ssh_guest 'ps -Ao comm= | grep -iE "Star Birds|Easy Red|Universe Sandbox" | grep -qv grep' >/dev/null 2>&1; then
    echo "   game process is up"
    break
  fi
  sleep 10
done
wait "$BURST"

echo "== present dumps: $(ls "$DUMPS" 2>/dev/null | wc -l) files in $DUMPS"
echo "== device census (this boot)"
for pat in color0_preserve_unhonoured present_black present_dump skip; do
  printf '  %-34s %s\n' "$pat" "$(grep -c "$pat" /tmp/reims-vgpu-fail.log 2>/dev/null)"
done
grep -m 3 'color0_preserve_unhonoured' /tmp/reims-vgpu-fail.log 2>/dev/null
echo "== draw refusals"
timeout 120 awk '
/linux_m2v_draw reason=/ { if (match($0, /reason=[A-Za-z_0-9]+/)) r[substr($0,RSTART+7,RLENGTH-7)]++; next }
/rt_resolve reason=/     { if (match($0, /reason=[A-Za-z_0-9]+/)) rt[substr($0,RSTART+7,RLENGTH-7)]++; next }
END {
  printf "  draw refusals:\n"; for (k in r) printf "  %8d %s\n", r[k], k | "sort -rn | head -6"; close("sort -rn | head -6");
  printf "  rt_resolve:\n";    for (k in rt) printf "  %8d %s\n", rt[k], k | "sort -rn | head -4"; close("sort -rn | head -4");
}' /tmp/reims-vgpu-fail.log 2>/dev/null

echo "== shutting the guest down"
ssh_guest "echo 12345678 | sudo -S shutdown -h now" >/dev/null 2>&1
for _ in $(seq 1 30); do pgrep -x qemu-system-x86_64 >/dev/null || break; sleep 4; done
echo "== done ($TAG)"
