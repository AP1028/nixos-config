# Cadence (virtuoso) on macbook via FEX-in-muvm — status & handoff

Goal: run Cadence IC25.1 `virtuoso` (x86_64) on the **macbook** (Apple Silicon,
aarch64, **16K-page kernel**) by emulating x86_64 with FEX inside a muvm microVM
(whose libkrunfw guest kernel is 4K-page). `box64` is not used for Cadence.

## Architecture

```
cadence-env -c 'virtuoso'
  └─ muvm -f <fex-cadence-rootfs> -m -x <bin-setup> -e DISPLAY -e XAUTHORITY -- <guest> "$@"
       └─ guest script sets env → exec tcsh -c 'virtuoso'
            └─ ~/.cadence/bin/virtuoso sets Cadence LD_LIBRARY_PATH → exec
               IC251/tools.lnx86/dfII/bin/64bit/virtuoso   (x86_64 ELF)
```

Key components (in `modules/env/cadence-env.nix`):
- `fex-cadence-rootfs` — erofs image of the x86_64 userspace (all system libs
  symlinked into `/usr/lib64`, `ld-linux-x86-64.so.2` at `/lib64`, aarch64
  ksh/tcsh/bash in `/bin`, plus SLES12 SONAME compat symlinks). `libc.so.6` is a
  **real file** (not symlink) so saSecurity sees `/usr/lib64/libc.so.6`.
- `cadence-env-guest-bin` (muvm `-x`, runs as root) — mounts tmpfs over `/bin`
  and `/usr/bin` and symlinks in aarch64 coreutils/gnused/gawk/gnugrep/procps +
  ksh/tcsh/bash/sh + hostname/domainname. (Needed because the VM's `/bin` only
  has `sh`, and the guest root is read-only for the mapped user.)
- `cadence-env-guest` — sets the Cadence env, then `exec tcsh "$@"`.
- `cadence-env` (aarch64 branch) — `sudo -E -u tianyixia -g no-internet muvm -f
  <rootfs> -m -x <bin-setup> -e DISPLAY -e XAUTHORITY -- <guest> "$@"`.

`hosts/macbook/system/default.nix` pins FEX 2608 (jemalloc 16K fix + `FEXInterpreter`
symlink) and applies these patches (all in `modules/env/`):
- `fex-fs-segment-store-fix.patch` — FS/GS segment base on vector stores (Issue 1).
- `fex-merged-rootfs.patch` — MergedRootFS config option + `/proc/<pid>/maps`
  rootfs-prefix rewrite + `/proc/<pid>/{statm,status}` vsize rewrite.
- `fex-tso-disable-gate.patch` — `FEX_DISABLE_HARDWARE_TSO` gate (unused escape hatch).
- `fex-crash-diag.patch` — dump guest registers on SIGSEGV/SIGBUS/SIGILL (debug).
- `muvm-no-network.patch` — adds a `--no-network` flag to muvm (currently unused;
  internet is blocked via the `no-internet` group instead).

## What is FIXED

1. **saSecurity "Failed to initialize"** — implemented MergedRootFS: muvm writes
   `MergedRootFS: "1"` into FEX's Config.json but FEX 2608 ignored it. Now FEX
   accepts it and rewrites `/proc/<pid>/{maps,smaps,smaps_rollup,numa_maps}` to
   strip the `/run/fex-emu/rootfs` prefix, so libc maps as `/usr/lib64/libc.so.6`.
2. **Library-manager launchers / 32-vs-64-bit** — the `/bin`+`/usr/bin` tmpfs and
   `/lib64`+`/usr/lib64` (host tmpfiles) fixed `#!/bin/ksh` "bad interpreter",
   `readlink not found`, and the `[ -r /lib64/. ]` 64-bit check.
3. **OA platform** — `OA_SYSNAME=linux_rhel80` fixes `lna64_rhel80` vs
   `linux_rhel80_64`. (`cds_root`/`cdsGetInstallRoot` themselves work fine under FEX.)
4. **Internet blocked** — `no-internet` group (import `modules/env/no-internet.nix`;
   run muvm via `sudo -g no-internet`) so passt's outbound is REJECTed fast.
5. **"Low Memory" / process size** — FEX now rewrites `/proc/<pid>/statm` +
   `/proc/<pid>/status` to report the resident size (647 MB) instead of its huge
   virtual reservation (131 TB). This killed the `Low Memory` spam but was **not**
   the launch-slowness cause.

## SOLVED: ~135s launch (`Virtuoso initialization`) → ~26s

`cadence-env -c 'virtuoso'` used to take ~135s. Root cause and fix are in
[ROOT CAUSE + FIX](#root-cause--fix-landed-the-30s-poll-is-qprocesswaitfor)
below. The historical investigation follows.

Corrected understanding (via FEX guest-execve tracing + strace of the FEX
process + `/proc/<pid>` sampling). The original "daemons spawn but exit"
theory was **wrong**:

- virtuoso's main thread does ~8.7s of CPU, then loops in `ppoll([...], 4,
  {tv_sec=30})` — a **30s-timeout poll that times out ~4x = ~120s**. It is a
  wait, not translation, and the poll is *not* a pipe-EOF failure: the
  `POLLHUP` from the `cds_root` child pipe **is** delivered correctly, then
  virtuoso deliberately re-enters a 30s poll with all fds set to `-1` (a sleep).
- The MPS daemons (`cdsNameServer`/`cdsMsgServer`/`cdsServIpc`) do **not** get
  spawned until **t≈133s** (after the stall); `clsbd` binds `0.0.0.0:16723` and
  is **never connected to** (node-locked license, so clsbd is orphaned). The
  stall is *before* the MPS startup, in virtuoso's early/static init.
- `cds_root` is spawned at t≈11s and t≈71s (60s apart), i.e. the 30s poll loop
  drives a retry of an install-root/platform check.
- The real `cdsMsgServer`/`cdsServIpc`/`cdsNameServer` all work fine once
  virtuoso finally starts them at t≈133s.

So the open question is now **what the 30s poll loop is waiting on during
virtuoso's early init (before it spawns the MPS daemons)**.

### Identified: the 30s poll is the Qt event loop

A `kill -USR1` FEX crash-dump + manual stack walk of the guest (FEX guest memory
is 1:1 mapped) shows the 30s `ppoll` is called from **`libcdsQt5Core.so`
(`QEventDispatcherUNIX::select()`)** — i.e. virtuoso's own Qt main event loop.
The 30s timeout is a pending `QTimer`, and the loop is a retry: the main thread
spawns `cds_root`, reads its output via pipes (fd 17/19, `POLLHUP` delivered
fine), then re-arms a 30s timer and polls with all fds `-1` (a sleep), ~4 times,
before finally spawning the MPS daemons at t≈133s. So the event loop is
deliberately spinning on a ~30s timer during early init; the thing that isn't
becoming ready fast enough (so the timer keeps re-arming) is still to be pinned
down — best candidates are the CLS/license handshake (clsbd binds 16723 and is
never connected) or the OA platform init.

### Fixes landed so far (necessary but NOT sufficient)

1. **`cds_root` "can't determine installation root"** — `cds_root` resolves
   `virtuoso` via `$PATH` and walks parent dirs for `tools/bin/cds_root`. The
   user wrapper `~/.cadence/bin/virtuoso` was **first in PATH** (outside the
   install tree), so `cds_root` found it and failed. Fix: the wrapper now
   re-orders `PATH` to put the install-tree bins first before exec'ing the
   64-bit binary. Tracked as `scripts/virtuoso-wrapper.sh` (install it at
   `~/.cadence/bin/virtuoso`).
2. **`cds_plat` reports the wrong platform** — it spawns `/bin/uname -m` (a
   native aarch64 binary) which returns `aarch64`, so `cds_plat` says `lna64`
   and `cds_root` prints `running cross platform: 'lnx86' on 'lna64'`. Fix:
   `modules/env/cadence-env.nix` now installs a `/bin/uname` wrapper that
   reports `x86_64` for `-m` (delegating everything else to coreutils), so
   `cds_plat` says `lnx86`. This is correctness-only; it did **not** remove
   the ~120s.

### ROOT CAUSE + FIX (landed): the 30s poll is `QProcess::waitFor*`

Pinned down with an x86_64 `LD_PRELOAD` interposer (built via
`pkgs.pkgsCross.gnu64`) that intercepts `ppoll`/`poll`/`select` + the Qt
`QTimer::start/setInterval` and `QObject::startTimer` and dumps a backtrace when
the poll timeout is ≥25s. The 30s poll backtrace is:

```
QCadenceStyle::QCadenceStyle() → init(bool) → initStyle()
  → applicationHierarchySupportsDarkTheme() → cdsRoot(QString)
    → QProcess::waitForStarted(30000) / waitForFinished(30000)
      → QEventDispatcherUNIX::select() → ppoll(30s)
```

i.e. the Cadence **Qt style** (`QCadenceStyle`) init runs `cds_root` through
`QProcess` and waits with the default **30 000 ms** timeout. Under FEX the
QProcess start/finish signal is never observed as ready, so each wait blocks the
full 30s; `cdsRoot` is called twice (t≈11s and t≈71s) → 4×30s ≈ 120s. There is
also a third 30s wait: `QProcess::~QProcess()` (in `libcdsQt5Core.so`) does
`kill()` + `waitForFinished(30000)`.

**Fix (binary patches, applied to the install tree, not the repo):**

| file | site | patch |
|---|---|---|
| `dfII/bin/64bit/virtuoso` | `QCadenceStyle::cdsRoot` `waitForStarted`/`waitForFinished` (VA 0x1ed611fb / 0x1ed61248 = file 0x1e9611fb / 0x1e961248) | `0x7530`→`0x7d0` (2000 ms) |
| `dfII/bin/64bit/virtuoso` | 9 other `QProcess::waitForStarted/Finished(30000)` sites (file 0x11f9d078, 0x11fe9447, 0x120ca32f, 0x120cacf6, 0x121db625, 0xc167401, 0x120ca350, 0x120cad18, 0x121db8d0) | `0x7530`→`0x7d0` |
| `dfII/bin/64bit/libManager` | `QCadenceStyle::cdsRoot` `waitForStarted`/`waitForFinished` + one more `waitForStarted` (file 0x95fe3b / 0x95fe88 / 0x2131c6) | `0x7530`→`0x7d0` |
| `Qt/v5/64bit/lib/libcdsQt5Core.so` | `QProcess::~QProcess` `waitForFinished(30000)` (VA/file 0x252688) | `0x7530`→`0x7d0` |

The patch is automated by `scripts/patch-cadence-qprocess-timeout.py` (checked
into this repo):

```
python3 scripts/patch-cadence-qprocess-timeout.py            # apply (idempotent)
python3 scripts/patch-cadence-qprocess-timeout.py --check    # report state
python3 scripts/patch-cadence-qprocess-timeout.py --revert   # undo
```

It backs each changed file up to `<name>.pre-qprocess-timeout` on first change.
Ad-hoc backups from the initial session: `virtuoso.orig-preload`,
`libcdsQt5Core.so.orig` (next to the patched files).

Result: **`cadence-env -c 'virtuoso'` launches in ~26s** (was ~135s):
`cds_root` re-spawn now at t≈15s (was t≈71s), `cdsNameServer` at t≈20s (was
t≈132s), "Virtuoso has launched" at t≈26s. The ~11s startup is FEX loading the
818 MB binary + libraries (not part of the stall). Could go lower (e.g. 500 ms)
if the remaining ~4s of `cdsRoot` wait is worth shaving; 2000 ms is chosen as a
safe margin over the FEX fork/exec latency of `cds_root`.

The **Library Manager (`libManager`) had the same stall** (its own copy of
`QCadenceStyle::cdsRoot`), reproduced standalone with
`libManager -unmapped -log …` (its `cds_root` re-spawn was at t≈34s). Patched
the same way — now `cds_root` re-spawns at t≈6s and `cdsNameServer` at t≈10s.
Other Cadence Qt tools (libSelect, layout, etc.) carry the same pattern and can
be patched the same way if they also load slowly.

Note: this patch is to the **installed Cadence tree** (`~/.cadence/IC251`), which
is not managed by Nix. A reinstall/re-extract of the Cadence install would undo
it — re-run the script after reinstalls (it recreates its own backups).

### How to (re)apply the fix — from git-tracked content only

Everything needed is in this repo; the only non-repo input is the Cadence
install itself at `~/.cadence/IC251` (installed separately, untouched by Nix).

1. **Build/rebuild the environment** (one-off; installs `cadence-env` + FEX +
   muvm with the guest scripts and the FEX patches in `modules/env/`):
   ```
   sudo-env -c 'nixos-rebuild switch --impure --accept-flake-config \
     --flake /home/tianyixia/nixos-config#macbook'
   ```

2. **Install the virtuoso wrapper** — fixes `cds_root` "can't determine
   installation root" (the cadence-env guest PATH puts `~/.cadence/bin` first,
   so this wrapper is what `cadence-env -c 'virtuoso'` runs), and on exit kills
   the detached daemons virtuoso leaves behind (`dashboard -runAsDaemon`, MPS
   `cdsNameServer`/`cdsMsgServer`/`cdsServIpc`, `clsbd`, …) so the stale
   `dashboard` tray icon doesn't block the next launch:
   ```
   install -m755 scripts/virtuoso-wrapper.sh ~/.cadence/bin/virtuoso
   ```

3. **Apply the launch-delay binary patches** (idempotent; backs each file up to
   `<name>.pre-qprocess-timeout` on first change):
   ```
   python3 scripts/patch-cadence-qprocess-timeout.py            # apply
   python3 scripts/patch-cadence-qprocess-timeout.py --check    # expect 11+3+1 OK
   ```
   Patches `tools.lnx86/dfII/bin/64bit/virtuoso` (11 sites),
   `tools/dfII/bin/64bit/libManager` (3 sites), and
   `tools.lnx86/Qt/v5/64bit/lib/libcdsQt5Core.so.5.15.9` (1 site) under
   `~/.cadence/IC251`: each `QProcess::waitForStarted/Finished(30000)` immediate
   `0x7530` → `0x7d0` (2000 ms). `--revert` undoes it.

4. **Make libManager's close (X) button exit instead of minimize** (idempotent;
    backs up to `<name>.pre-close-exit`):
    ```
    python3 scripts/patch-libmanager-close-exit.py          # apply
    python3 scripts/patch-libmanager-close-exit.py --check  # expect 1/1 OK
    ```
    `cdsLibManager::closeEvent` only quits when `mpsOpWaiting == 0`; otherwise it
    `QWidget::hide()`s — the "pseudo-minimize" that unmaps the window and can hit
    the Xwayland damage busy-loop (see "UNRESOLVED" below). Patch the `je`→`jmp`
    at vaddr `0x603e3a` (file off `0x203e3a`) so close always quits. `--revert`
    undoes it.

5. **Verify** (use the real `cadence-env`, not hand-rolled env — see gotcha below):
    ```
    cadence-env -c 'virtuoso'              # "Virtuoso has launched" at ~26s
    libManager -unmapped -log /tmp/lm.log  # cds_root re-spawn at ~6s
    ```
    Timing: `cds_root` re-spawn at t≈15s (was t≈71s), `cdsNameServer` at t≈20s
    (was t≈132s). The ~11s before the first `cds_root` is FEX loading the 818 MB
    binary + libs — not part of the stall.

6. **Re-diagnose a stall if it regresses** (the interposer that found this bug):
   build it (cross-compiles the x86_64 `.so` from the aarch64 host), run the tool
   under `LD_PRELOAD`, and resolve the logged backtraces — see
   `scripts/qtimer-preload/README.md`. The stall signature is a `ppoll` with
   `tv_sec >= 20`; resolve the logged addresses with the nixpkgs
   `x86_64-unknown-linux-gnu-addr2line` against the tool's binary/libs.

### Test-harness gotcha (important — do NOT repeat this)

My earlier "~17s launch" claims were **bogus**: several of my scripts did
`export CDSBASE="$HOME/.cadence" CDS_INST_DIR="$CDSBASE/IC251" ...` in a **single**
`export` statement. In POSIX shell the `$CDSBASE` in `CDS_INST_DIR` is expanded
*before* the assignment, so `CDS_INST_DIR=/IC251` (empty `CDSBASE`). That makes
virtuoso fail to find its install (`CMGR-7001`) and **skip the full init**, which
is why those runs were fast. Always use **separate `export` statements**. The
real `cadence-env` sets them separately and is correct.

## Key facts / reproduction

Build (no system rebuild needed):
```
nix eval --impure --accept-flake-config ~/nixos-config#nixosConfigurations.macbook.config.environment.systemPackages \
  | grep -oE '/nix/store/[a-z0-9]+-cadence-env\.drv' | head -1   # then
nix-store --realise <that .drv>
```
Rebuild/install: `sudo-env -c 'nixos-rebuild switch --impure --accept-flake-config
--flake /home/tianyixia/nixos-config#macbook'`.

Run: `cadence-env -c 'virtuoso'` → "Virtuoso has launched" at ~26s (was ~135s);
the Library Manager (`libManager`) is fast now too. See "How to (re)apply the fix"
above for the exact recreate steps.

Debug tools:
- `fex-crash-diag.patch` + `-e FEX_SILENTLOG=0 -e FEX_OUTPUTLOG=/run/muvm-host/tmp/opencode/fex.log`
  then `kill -11 <pid>` dumps the guest RIP.
- Sample the hang with `/proc/<pid>/stat` (`utime` = CPU), `/proc/<pid>/wchan`,
  `/proc/<pid>/syscall`, and the `comm` of all `/proc/*/` to see which daemons
  are up.

## Files in repo (all git-tracked)

Runtime env (nix):
- `modules/env/cadence-env.nix` — the `cadence-env` env: FEX rootfs +
  `/bin`/`/usr/bin` guest setup (+ strace/gdb), the `/bin/uname` x86_64 wrapper,
  the guest script (Cadence env + `QT_SCALE_FACTOR=2` HiDPI, aarch64-only),
  the `sudo -g no-internet` muvm wrapper, and the `/lib64` tmpfiles.
- `hosts/macbook/system/default.nix` — FEX 2608 overlay + patch list.
- FEX patches under `modules/env/`: `fex-fs-segment-store-fix.patch`,
  `fex-merged-rootfs.patch`, `fex-tso-disable-gate.patch`, `fex-crash-diag.patch`
  (SIGSEGV/BUS/ILL/USR1 register + frame-walk dump), `fex-execve-log.patch`
  (guest-execve tracing via `FEX_EXECVE_LOG`), `muvm-no-network.patch`.
- `hosts/macbook/default.nix` / `modules/env/no-internet.nix` — the
  `no-internet` group (guest outbound REJECTed fast).

The launch-delay fix (binary patches, applied to the install tree by a script):
- `scripts/patch-cadence-qprocess-timeout.py` — apply/check/revert the
  `0x7530`→`0x7d0` patches (virtuoso 11 sites, libManager 3, libcdsQt5Core 1).
- `scripts/virtuoso-wrapper.sh` — installed at `~/.cadence/bin/virtuoso`
  (LD_LIBRARY_PATH + PATH reorder; see fix #1).

Diagnostic tooling:
- `scripts/qtimer-preload/` — x86_64 `LD_PRELOAD` interposer (`qtimer_preload.c`
  + `qtimer.map` + `build.nix` + `README.md`) that dumps a backtrace on a
  `ppoll` ≥20s; used to pin the stall to `QProcess::waitFor*`.

Docs: `docs/cadence-fex.md` (this file).

NOTE: **unrelated concurrent changes** from another agent (`packages/steam-arm64*`,
`modules/packages/steam-arm64.nix`, and the `steam-arm64` lines in
`hosts/macbook/packages/default.nix`) — leave them alone.

## UNRESOLVED: DE freeze on closing Library Manager (Xwayland)

### Symptom

`cadence-env -c 'virtuoso'` → open Library Manager (`libManager`) → hit
close/exit on the libManager window → the **whole KDE desktop freezes**
(kwin/Xwayland hang, not a SIGSEGV — no coredump entry). Requires a hard reset.
Also reproduced on **asusg16 (x86_64, native virtuoso)** — so it is **not**
FEX/muvm-specific.

### What it is NOT

- The close button **minimizing** the libManager window is its **normal**
  behaviour — identical on X11 and Wayland. It is *not* the bug.
- X11: clean (closing libManager on an X11 session does not hang).

### What it IS

- A **Wayland/Xwayland-specific hang**, triggered *intermittently* (not every
  close), on closing the libManager window.
- It is a **hang** (freeze), not a crash: kwin's main thread stays in its idle
  `ppoll` (QEventDispatcherUNIX::processEvents) — so the stuck component is
  likely **Xwayland** or a kwin worker/GPU path, not kwin's main loop.

### Debugging gotcha (Heisenbug — do NOT repeat)

Any **continuous** observation perturbs the race and makes the close *minimize*
instead of freeze:
- a watchdog polling kwin CPU every 1s (`ps`) → minimize;
- a periodic gdb attach every 15s → minimize.

The one method that reproduces the freeze is a **single-shot**: leave the
process completely alone for ~10s while the user closes the window, then attach
gdb **once** (`sleep 10; gdb -p <pid> -ex bt -ex "thread apply all bt"`). So any
capture tooling must be single-shot / delayed, never polling.

### Capture setup

- `sshd` is enabled on macbook (`ssh tianyixia@192.168.1.91`, password auth) so
  the machine can be reached while the DE is frozen (the frozen DE kills the
  local terminal).
- Single-shot capture helper (tracked): `scripts/capture-kwin-xwayland.sh`
  (sleeps `DELAY` s, then one gdb attach to kwin + Xwayland → `~/.cadence/freeze_dump.log`).
  Run as root with `sudo-env -c 'setsid -f bash scripts/capture-kwin-xwayland.sh 10'`
  (needs `sudo-lock` armed).
- Manual equivalent: `sudo-env -c 'gdb -q -batch -p <kwin> -ex bt -ex
  "thread apply all bt"'` and the same for `Xwayland` (`pgrep -x Xwayland`).

### Root cause (captured)

The freeze is a **busy-loop in Xwayland's damage/composite extension**; kwin is
just a victim. Captured backtraces (saved in `docs/freeze-dump.log`):

Xwayland main thread (spinning, `Rl`, wchan empty):
```
damageRegionProcessPending()  (miext/damage/damage.c)
damageCopyArea()              (miext/damage/damage.c)
compRestoreWindow()           (composite/compalloc.c)
compCheckRedirect()           (composite/compwindow.c)
compUnrealizeWindow()         (composite/compwindow.c)
UnrealizeTree() -> UnmapWindow() -> ProcUnmapWindow() -> Dispatch() -> dix_main()
```

kwin main thread (blocked in `xcb_wait_for_reply`):
```
xcb_wait_for_reply <- NETWinInfo::update <- KWin::X11Window::windowEvent
  <- Workspace::workspaceEvent <- Xwayland::dispatchEvents
```

Mechanism: closing the libManager window → `UnmapWindow` → the composite
extension unredirects the window (`compCheckRedirect` → `compRestoreWindow`),
copying the saved pixmap back via the damage-wrapped `CopyArea`
(`damageCopyArea`), which then spins in `damageRegionProcessPending` — the
damage extension's pending-damage list becomes circular when a window is
damaged and then unrealized before the damage is processed. kwin blocks forever
waiting for Xwayland's reply.

Note: the 2018 xorg-server fix "xwayland: remove dirty window unconditionally
on unrealize" (the `xorg_list_del(&xwl_window->link_damage)` in
`xwl_window_dispose`) is **already present** in xwayland 24.1.13 — this is the
*other* (core `miext/damage`) list, so a further fix is still needed.

### Workaround (landed): timing-perturbation poller in cadence-env

The `compRestoreWindow`→`damageCopyArea`→`damageRegionProcessPending` spin is a
*timing race* — any per-second fork/exec against the compositor changes the
scheduling enough that the close minimizes instead of hanging (the Heisenbug
above, turned into a fix). `modules/env/cadence-env.nix` now starts, in the
`cadence-env` wrapper (both aarch64 and x86_64), a background poller that runs
`pgrep kwin_wayland` + `ps -o pcpu= -p <kwin>` once a second; a `trap … EXIT`
kills it when the session ends (on x86 the FHS env does not destroy a VM, so the
explicit trap is what reaps the poller there). One poller per session is
negligible. This mirrors the watchdog that first made the crash disappear.

### Additional mitigation (landed): libManager close = exit, not minimize

The trigger is libManager's "pseudo-minimize": `cdsLibManager::closeEvent` only
calls `QCoreApplication::quit()` when `mpsOpWaiting == 0`; otherwise it
`QWidget::hide()`s the window — an unmap (not a destroy) that goes through
`compUnrealizeWindow`/`compRestoreWindow` and can hit the damage spin.
`scripts/patch-libmanager-close-exit.py` patches the `je`→`jmp` at vaddr
`0x603e3a` (file off `0x203e3a`) so the close (X) button always quits and the
window is destroyed rather than merely unmapped — a cleaner bypass than the
poller, pending verification. Idempotent + revertible (backup
`<name>.pre-close-exit`).

### Not done (deferred): the real Xwayland fix

The proper fix is a guard in `miext/damage/damage.c:damageRegionProcessPending`
(a circular damage list makes it spin; see `docs/freeze-dump.log`). A Nix
overlay that patches xwayland forces a rebuild of the **entire plasma/KDE stack**
(downstream of xwayland), which is unacceptable since plasma is a flake-updated
moving target. A binary patch of the installed Xwayland is blocked by the
read-only Nix store. So the poller workaround is the pragmatic fix for now; the
source patch (`xwayland-24.1.13`, `modules/env/xwayland-damage-cycle.patch` was
prototyped and reverted) can be revisited if the poller ever stops working.

## Handoff

The launch delay is SOLVED (see "How to (re)apply the fix" above): the ~135s
stall was `QCadenceStyle::cdsRoot()` → `QProcess::waitForStarted/Finished(30000)`
blocking ~4×30s under FEX. Patched to 2s via
`scripts/patch-cadence-qprocess-timeout.py` (virtuoso + libManager +
libcdsQt5Core). `cadence-env -c 'virtuoso'` launches in ~26s.

If a new/regressed stall appears, build + run `scripts/qtimer-preload/` and
resolve the `ppoll` backtrace (see its README). The same `QCadenceStyle::cdsRoot`
pattern is compiled into other Cadence Qt tools (libSelect, layout, dashboard, …)
— patch them the same way if they load slowly (add their `0x7530` `waitFor*`
sites to the patch script).
