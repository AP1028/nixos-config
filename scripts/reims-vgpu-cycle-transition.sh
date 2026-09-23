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
  # `_windowserver` owns the console while the login window is up, before
  # anyone has logged in; the desktop this cycle needs is the one that comes
  # after that, so an underscore-prefixed owner is not the answer.
  case "$user" in
    "" | root | _*) ;;
    *)
      echo "   console user $user"
      break
      ;;
  esac
  sleep 5
done
# The Steam client updates itself on a fresh boot and puts up a modal
# "Updating Steam… Verifying installation…" sheet. Launching into that sheet
# does nothing but leave a cycle measuring the desktop, which is exactly what
# happened once, so wait for the client to own a window before asking it to
# start a game. `steamwebhelper` is the client UI; its presence plus a quiet
# package dir is the cheapest "not mid-self-update" signal available over SSH.
echo "== waiting for Steam to settle (STEAM_SETTLE=${STEAM_SETTLE:-180}s cap)"
for _ in $(seq 1 36); do
  busy="$(ssh_guest 'ps -Ao comm= | grep -c "[s]team_osx"' 2>/dev/null | tr -d '\r')"
  [ "${busy:-0}" -gt 0 ] && break
  sleep 5
done
sleep "${STEAM_SETTLE:-180}"

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
# A process is not a window, and the window is what the cycle is about: the
# check above answered "process is up" for a title that never drew a frame, and
# the only presented content was the Steam client. Ask the guest for registered
# applications by name and for the Unity log the title itself writes, and print
# what answered. `lsappinfo` needs no Accessibility grant, unlike a window list
# through System Events.
echo "== launch evidence"
ssh_guest 'lsappinfo list 2>/dev/null | grep -iE "Star Birds|Easy Red|Universe Sandbox" | head -4' 2>/dev/null
ssh_guest 'log="$HOME/Library/Logs/Toukana Interactive/Star Birds/Player.log"; \
  if [ -f "$log" ]; then echo "Player.log $(stat -f%z "$log") bytes, mtime $(stat -f%Sm "$log")"; tail -3 "$log"; \
  else echo "no Player.log"; fi' 2>/dev/null
# If no window answered, launch the title's own bundle: `steam://rungameid` is
# handled by the client's web layer, and a black client content area means that
# layer is exactly what is not running. `open -a` lands the process in the
# logged-in console session; Steamworks only needs the client up, which it is.
if ! ssh_guest 'lsappinfo list 2>/dev/null | grep -qiE "Star Birds|Easy Red|Universe Sandbox"' 2>/dev/null; then
  echo "== no window yet: trying the title's own bundle"
  bundle="$(ssh_guest 'ls -d "$HOME/Library/Application Support/Steam/steamapps/common"/*/*.app 2>/dev/null | head -1' | tr -d '\r')"
  echo "   bundle=${bundle:-none found}"
  if [ -n "$bundle" ]; then
    ssh_guest "open -a \"$bundle\"" >/dev/null 2>&1
    for _ in $(seq 1 12); do
      ssh_guest 'lsappinfo list 2>/dev/null | grep -qiE "Star Birds|Easy Red|Universe Sandbox"' 2>/dev/null && {
        echo "   bundle launch answered a window"
        break
      }
      sleep 10
    done
  fi
fi
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
