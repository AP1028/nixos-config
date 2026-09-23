# Debugging a game on the reims-vgpu macOS guest, agentically

How to drive the whole loop — boot, launch, observe, diagnose, shut down — from an
agent with SSH, screenshots, and desktop automation, and where each method is the
right one. Companion to [`reims-vgpu-black-3d-scene.md`](./reims-vgpu-black-3d-scene.md)
(the investigation) and [`reims-vgpu-code-assessment.md`](./reims-vgpu-code-assessment.md)
(the patch audit and the Star Birds cycles).

The one-cycle entry point is [`scripts/reims-game-test.sh`](../scripts/reims-game-test.sh).
Read this file when the cycle needs to change, not just run.

---

## 1. The loop

```
host: run-game.sh <qemu-bin> <tag>        # boot, logs truncated, SSH waits
  └─ tmux session "reims" ─ QEMU ─ device ─ winit window on the host desktop
guest (ssh, key ~/.ssh/id_ed25519, user tianyixia, password 12345678):
  steam_osx steam://rungameid/<appid>     # launch a title
  ps / lsappinfo / tail Player.log        # is it alive, foreground, at the menu?
observe:
  host: spectacle -b -n -f -o shot.png    # the ONLY faithful frame view
  guest: screencapture -x                 # text/UI state only; see §4.2
  device: /tmp/reims-vgpu-fail.log, /tmp/reims-vgpu-draw.log  (censuses)
shutdown:
  ssh … 'echo 12345678 | sudo -S shutdown -h now'
```

Discipline that keeps this cheap: **one change, one cycle**. A cycle is ~4–6 minutes
(boot ~2, launch ~1, capture, census, shutdown). If two cycles in a row produce the
same symptom with no new counter moving, stop and re-read the code instead of booting
a third time.

---

## 2. Host and guest access

| Thing | Value |
|---|---|
| Guest SSH | `ssh macos-vm` → `localhost:2222`, key `~/.ssh/id_ed25519`, user `tianyixia` |
| Guest password | `12345678` (temporary), used as `echo 12345678 \| sudo -S …` over SSH |
| Guest OS | macOS 13.7.8 x86_64, SIP disabled in OpenCore NVRAM (so `dtrace` works) |
| Host desktop | KDE Plasma 6, Wayland (`WAYLAND_DISPLAY=wayland-0`), 2560×1600 |
| Elevated host commands | `sudo-env -c '<command>'` (the session has no interactive sudo) |
| Build | `nix build --impure --no-link --print-out-paths -f /tmp/opencode/reims-qemu.nix` |
| Boot helper | `/tmp/opencode/run-game.sh <qemu-bin> [tag]` (see §3) |

Steam app ids seen in this guest's library: **Star Birds 2719750**, Easy Red 2 1324780,
Universe Sandbox 230290. Manifests live in
`~/Library/Application Support/Steam/steamapps/appmanifest_*.acf`
(`grep -E '"appid"|"name"|"StateFlags"'`).

---

## 3. Booting, and what QEMU is actually doing

`run-game.sh` shuts down any running guest first (over SSH, waiting for the qcow2
locks to drop — a hard kill races the write lock and the next boot dies on
"Failed to get write lock"), truncates both device logs, kills the `reims` tmux
session, then boots:

```
tmux new-session -d -s reims "cd ~/reims-vgpu && exec env QEMU_BIN=<bin> \
  REIMS_VGPU_LAZY_WRITEBACK=off REIMS_VGPU_DRAW_LOG=on \
  reims-vgpu-boot --rail macos-13 --persistent --device reims-vgpu-pci \
  > /tmp/opencode/run-<tag>-boot.log 2>&1"
```

Two consequences worth knowing:

- **Extra device env vars must be inside the tmux command.** `tmux new-session`
  inherits the *server's* environment, so exporting a variable in your shell before
  calling `run-game.sh` does nothing. For the opt-in diagnostics, start the session
  yourself with the variable added (`REIMS_VGPU_DIAG_CHAIN_READBACK=1` is the one in
  use; see §5.3).
- **QEMU has no console surface.** The boot line ends in `-display none`, and the
  guest's frames are presented by the *device's own* winit window
  (`reims-vgpu-window: first guest frame presented via rail resident`). So
  QMP/HMP `screendump` has nothing to capture; see §4.1.

`--persistent` boots the provisioned masters write-through, so a guest crash costs the
session (the default rails snapshot-revert). Boot takes ~90–120 s to SSH.

---

## 4. Observation

### 4.1 The host window is the ground truth

```sh
spectacle -b -n -f -o /tmp/opencode/shots/<tag>-host.png      # full desktop
ffmpeg -y -loglevel error -i <shot>.png \
  -vf "crop=1200:720:200:170,scale=900:-2" <shot>-crop.png    # the Reims window
```

Then read the PNG with the model's image input. The Reims window sits near
`x=200,y=170` at 2560×1600 with the default layout; crop and adjust. `spectacle -a`
(active window) works when the Reims window has focus, `-u` captures the window under
the cursor.

Colour is diagnostic: a guest system dialog, the menu bar, or a window's contents
appearing while the rest is black says the present path and WindowServer drawing work,
and the missing part is composited *client* content — which is a very different lead
from "nothing is presented at all".

### 4.2 The guest's own `screencapture` is not faithful here

```sh
ssh macos-vm 'screencapture -x /tmp/g.png' && scp -q macos-vm:/tmp/g.png .
```

On this rail it returned **two wallpaper panels and no windows** while the host window
showed the full desktop with Steam, the menu bar and the dock. Do not use it to decide
what the guest displays; use it only as a rough check of the desktop's presence.
Its disagreement with the host window is itself a signal (see the cycle-3 note in the
assessment doc: a WindowServer-drawn dialog rendered, the composited desktop did not).

### 4.3 Guest-side text evidence (SSH, no permissions needed)

| Question | Command |
|---|---|
| Is the game alive / how much CPU? | `ps -Ao pid,pcpu,etime,comm \| grep -i "star birds"` |
| Is it foreground, does it have an app entry? | `lsappinfo list \| grep -iA3 star` (`(in front)`, `type="Foreground"`) |
| What did the game's engine do? | `tail -40 ~/Library/Logs/<vendor>/<game>/Player.log` |
| Where is the log? | `find ~/Library/Logs -iname Player.log -newermt "-10 minutes"` |
| What is it doing right now? | `sample "$(pgrep -f 'Star Birds')" 3 -file /tmp/sample.txt` (bounded) |
| WindowServer/GPU complaints | `log show --last 2m --style compact --predicate 'process == "Star Birds"'` (slow; bound it) |

Unity log directories on this guest: **Toukana Interactive → Star Birds**,
**Corvostudio → Easy Red 2**, Giant Army → Universe Sandbox, Jundroo → SimplePlanes.
The Star Birds menu is reached when the log prints
`Set Cursor State by Scene: MainMenu` and music starts; that is the moment to capture.

### 4.4 Device-side censuses

Both logs are truncated at boot, so everything in them belongs to the current cycle.

```sh
# top refusal reasons, one pass over the fail log
awk '/linux_m2v_draw reason=/ { if (match($0,/reason=[A-Za-z_0-9]+/)) r[substr($0,RSTART+7,RLENGTH-7)]++ }
     /rt_resolve reason=/     { if (match($0,/reason=[A-Za-z_0-9]+/)) t[substr($0,RSTART+7,RLENGTH-7)]++ }
     /blit_fail reason=/      { if (match($0,/reason=[A-Za-z_0-9]+/)) b[substr($0,RSTART+7,RLENGTH-7)]++ }
     END { for (k in r) print r[k], "draw", k; for (k in t) print t[k], "rt", k; for (k in b) print b[k], "blit", k }' \
  /tmp/reims-vgpu-fail.log | sort -rn | head -20

# a counter from the newest census line
grep -a store_routes /tmp/reims-vgpu-draw.log | tail -1 | tr ' ' '\n' | grep -E 'wbdebt_|chain_|gvarung|sampled_'

# what the device did over time
grep -a -E 'drain_duty|gpu_span|chain_phase|host_window_loop|host_window_cadence' /tmp/reims-vgpu-draw.log | tail -20

# stored frame content (1920x1080 BGRA/HDR): rgb_nz=2073600 is every pixel nonzero
grep -a m2v_store_gva /tmp/reims-vgpu-draw.log | tail -5
```

Counters worth reading first, per symptom:

- **Draws refused / nothing renders**: `linux_m2v_draw reason=…`, `rt_resolve reason=…`,
  `blit_fail reason=…`, `draw_encode_fail`, `draw_fail_clear_fallback`.- **Black window with draws succeeding**: `sampled_direct_declined`,
  `sampled_admit_no_identity`, `wbdebt_texture_owes_nothing{,_resolved,_unresolved}`,
  `gva_resident_authoritative`, `gvarung_resident`, `chain_gva_debt_armed` /
  `chain_gva_debt_declined`, and the stored-frame content above.
- **Slow**: `drain_duty duty=…`, `draw_phase`, `chain_phase sampled_us=…`, `gpu_span`.
- **Memory**: `vk_slab_allocate_memory`, `vram_pool_reclaim_retry … held_bytes=`,
  `vk_alloc_sites`.

Opt-in probes: boot with `REIMS_VGPU_DIAG_CHAIN_READBACK=1` to get
`diag_chain_target` (the chain target's task/ref/gva/format/geometry),
`diag_sample_probe` (each depth-sample candidate plus `debt=` at that address) and
forced chain readbacks. It is expensive; use it for one cycle when the debt/identity
question is open.

### 4.5 A census locates; only the pixels decide

`REIMS_VGPU_PRESENT_DUMP=<dir>` writes the resident the window is about to present as a
P6 PPM. It answers "what did the device actually put on screen", which no counter can,
but a *derived metric* over it is a locator and never a verdict. Real case, cycle 10:

```sh
# per-row census: how many rows are red-saturated, in how many bands
scripts/reims-vgpu-ppm-rows.py /tmp/opencode/dumps-fresh
present-dump-3.ppm 1920x1080 mean=(230,142,61) red_rows=822/1080 bands=3 flips=5
```

That reads like a stale-frame artifact and was written up as one — full-frame red bands
at the launch transition, the exact orange the user described where red met the ocean's
blue. Opening the same file showed macOS 13's own **Ventura wallpaper** (an orange/red
swirl) with Steam's update sheet over it. The guest's legitimate desktop has the same
row signature as corruption invented by the device, because the metric only knows
"rows whose mean is red-dominant".

So: use counts to choose *which* frames to open, then open them (`ffmpeg -i x.ppm
x.png`, then read the image). Corollaries from the same cycle:

- **Capture the transition, not a frame.** The interesting event is at a transition; a
  single capture 20 s after "the game process exists" can miss it entirely. A burst
  (`for i in $(seq -w 1 40); do spectacle -b -n -f -o shot-$i.png; sleep 2; done &`)
  started *before* the launch covers the window, and the present dumps' own sampling
  window has to be wide enough to reach it — `call % 32` spent all forty dumps on the
  pre-paint frames of a boot, `call % 256` reaches ten thousand presents.
- **Check the guest is doing what you think.** Cycle 10's title never launched: Steam
  was updating itself ("Updating Steam… Verifying installation…"), which the dump showed
  and no counter did. A cycle that measures the wrong workload still produces numbers.
- **`spectacle -f` captures the whole host screen**, VM window included, so its frames
  need cropping before any per-row logic means anything; the device's own dumps have no
  such problem.

---

## 5. Input, when a menu needs it

Preference order:

1. **Nothing** — many titles need no interaction (Star Birds reaches its menu alone).
2. **QEMU's own keyboard**, injected at the USB device, needing no guest permissions
   and no window focus rules. The boot leaves a QMP socket at
   `~/reims-vgpu/vm/disks/run/qmp-*.sock`; `scripts/reims-game-test.sh` has a
   `qmp_key()` helper that speaks the QMP handshake and issues
   `{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"spc"}]}}`.
   QEMU's `send-key` is the same key injection the HMP `sendkey` monitor command uses.
3. **Guest-side AppleScript** — `osascript -e 'tell application "System Events" to key
   code 49'` (space) or `click at {x,y}`. Needs Accessibility permission for the SSH
   session's process, so it is the last resort, not the first.
4. **Host desktop automation** — only if a click must land on the *host* window
   (focus, window management). `spectacle` for capture; for input the host session has
   no `ydotool`/`wtype`/`xdotool` installed, so this needs a `nix-shell -p ydotool`
   (or similar) and is rarely necessary because the guest receives input directly.

---

## 6. The one-cycle scripts

```sh
scripts/reims-game-test.sh <qemu-bin> <tag> [appid]     # default appid 2719750
scripts/reims-vgpu-cycle-transition.sh <qemu-bin> <tag> [appid] [device-env]
```

`reims-game-test.sh` boots, launches, waits for the game process, captures host
(`<tag>-host.png`) and guest (`<tag>-guest.png`) into `/tmp/opencode/shots/`, prints the
refusal census, and shuts the guest down. Read the host PNG before believing anything
else; its single capture answers "what does the menu look like".

`reims-vgpu-cycle-transition.sh` is the same cycle aimed at the *transition*: it waits for
the guest's own console session, starts a 40-frame host burst, launches the title under
the burst, then prints the census (including `color0_preserve_unhonoured`, `present_black`
and the dump count) before shutting the guest down. It takes a device env (default
`REIMS_VGPU_VK_DEVICE_TYPE=integrated`), adds `REIMS_VGPU_PRESENT_DUMP`, and writes the
dumps to `/tmp/opencode/dumps-<tag>/`. Its per-row census helper is
`scripts/reims-vgpu-ppm-rows.py`, whose counts locate frames to open — see §4.5 for why
they never decide.

---

## 7. DSH-native computer use

The harness has a computer-use capability (`packages/computer-use`, providers under
`packages/experimental/computer-use-cua-driver-*`) but **no provider is mounted in a
default session**: the web profile's bundles are
`@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` only, and the tool list of a
running session cannot be extended. The upstream driver is present in the harness's
`node_modules` (`@trycua/cua-driver@0.28.0` plus `@trycua/cua-driver-linux-x64-gnu`),
so enabling it is a composition change plus a harness restart:

```yaml
# ~/.dsh/profiles/web/cordis.patch.yml (or the profile's package.json bundles)
- name: '@deepseek-ai/dsh-computer-use'
- name: '@deepseek-ai/dsh-experimental-computer-use-cua-driver-native'
```

Then a session gets the driver's own tool catalog (screenshots returned as attachments
need an image-capable model route and an attachment store). The native provider runs
in-process — a native crash takes the harness with it — and macOS cursor-overlay
support and permission UI are upstream/deferred. The MCP variant
(`…-cua-driver-mcp`) instead wants an installed `cua-driver mcp` executable.

Until that is mounted, §4.1's `spectacle` capture plus the SSH commands in §4.3 *are*
the computer use for this workflow, and they are what the cycle script uses. They have
one advantage over a generic desktop driver: they name the guest's own state
(`lsappinfo`, `Player.log`) instead of inferring it from pixels.

---

## 8. Gotchas collected from real cycles

- **Disk locks**: never `kill -9` QEMU; shut down over SSH first, or the next boot fails
  on the qcow2 write lock. `run-game.sh` already does this.
- **`pgrep -f qemu-system-x86_64` matches itself** when run from a shell whose command
  line contains the pattern — a "VM still running" reading from that is often your own
  grep. Use `ps -eo pid,stat,comm | awk '$3 ~ /qemu/'` to be sure.
- **tmux environment**: extra `REIMS_VGPU_*` variables must be in the `tmux new-session`
  command (§3).
- **`.orig` files** appear next to files whose patch applied at an offset; they are
  noise, but their presence means the patch did not apply exactly.
- **A boot that logs `boot-x86.sh: persistent boot exited rc=0` and leaves no QEMU
  process** is a clean exit (e.g. a guest shutdown), not a crash.
- **Guest `screencapture` lies** on this rail (§4.2) — a wallpaper-only capture proves
  nothing about the desktop.
- **Log evidence beats speculation**: every claim in the assessment doc's cycles came
  from a counter, a refusal line or a stored-frame content field; when a hypothesis has
  no counter to move, that is the moment to add one (or to stop and ask), not to boot
  again.
