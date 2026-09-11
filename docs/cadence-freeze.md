# Xwayland DE freeze on Cadence close/minimize — root cause and fix

Status: **RESOLVED on both machines** (2026-09-06). Closing / minimizing /
exiting Cadence windows used to wedge the whole KDE desktop through an
Xwayland damage-extension spin. The fix is server-side: a patched Xwayland
(`packages/patched-xwayland.nix`) wired into both host configs. Cadence
binaries are **stock** on both machines (asusg16 fully stock; the macbook
additionally carries only the FEX launch-delay patch — see
`docs/cadence-fex.md`, that is a separate bug).

## Runbook (what to do)

- **Normal operation: nothing.** The patched Xwayland is built and shadowed in
  automatically by `hosts/asusg16/packages/default.nix` and
  `hosts/macbook/packages/default.nix`; it activates when kwin spawns the next
  session (relogin after a rebuild).
- **After a nixpkgs bump**, the derivation locates the patch site itself:
  `packages/patch-xwayland-comp-restore.py` reads `compRestoreWindow`'s
  address/size from the symbol table and finds the unique GC-ops `CopyArea`
  call inside it (x86_64: `call *0x18(%rax)`; aarch64:
  `ldr xN,[xM,#0x18]` + `blr xN`). Rebuilds that only shift the code layout
  are absorbed automatically; if the build still fails (symbols stripped or
  pattern no longer unique), re-derive manually with `nm`/`objdump` and
  adjust the matcher in the script.
- **Cadence binaries stay stock.** Do **not** apply anything from
  `scripts/attic/` — those are the retired client-side freeze workarounds
  (kept for reference, see the RETIRED section below). The only live Cadence
  binary patch is the macbook's FEX launch-delay fix
  (`scripts/patch-cadence-qprocess-timeout.py`) — unrelated to the freeze;
  re-apply it after an IC reinstall per `docs/cadence-fex.md`.
- **If a freeze ever reappears**: arm
  `scripts/capture-kwin-xwayland.sh` (see Diagnostics) and check
  `~/.cadence/freeze_dump.log`. If the spin still passes through
  `compRestoreWindow`, something re-broke the Xwayland patch; if it found a
  new door, see the loop-guard fallback below.

## Root cause (confirmed by backtrace, 2026-09-06)

Captured live with `scripts/capture-kwin-xwayland.sh` while the DE was wedged
(`~/.cadence/freeze_dump.log` on asusg16; `docs/freeze-dump.log` is the
macbook's earlier capture). Xwayland's single dispatch thread spins inside the
teardown of the just-disconnected libManager client:

```
CloseDownClient -> FreeClientResources -> doFreeResource -> DeleteWindow
  -> UnmapWindow -> UnrealizeTree -> compUnrealizeWindow -> compCheckRedirect
  -> compRestoreWindow -> damageCopyArea -> damageRegionProcessPending  (spin)
```

(macbook aarch64 capture shows the same spine via `ProcUnmapWindow`; kwin's
main thread sits blocked in `xcb_wait_for_reply ← NETWinInfo::update ←
KWin::X11Window::windowEvent ← Xwayland::dispatchEvents` — a victim, not the
cause.)

Key facts:

- **Destroy is NOT safe in xwayland-24.1.13**: `DeleteWindow` itself goes
  through `UnmapWindow -> compRestoreWindow`. The earlier "destroy path does
  not restore" assumption is wrong for this build. Any client exit frees its
  windows server-side; nothing client-side can prevent it.
- **`compRestoreWindow`'s blit is the only door.** The spin lives in
  `damageRegionProcessPending`, walking a corrupted (circular) per-drawable
  damage chain, reached here through the damage-wrapped `CopyArea` that
  `compRestoreWindow` uses to copy the redirection pixmap back on unrealize.
  Every observed freeze — unmap on close, iconify, exit teardown, disconnect —
  passes through that single blit.
- The damage chain is corrupted on **libManager's own windows**, created by
  the graceful shutdown path: killing libManager externally (wrapper pkill at
  virtuoso exit) tears the same windows down cleanly, while quitting from the
  X button/File→Exit wedges. Mechanism unknown (an Xwayland bookkeeping bug;
  the clients do not even use the X Damage extension). On real X11 there is
  no composite-restore-unmap path, which is why X11 never froze.
- Symptom mapping: the wedge starts at disconnect → Xwayland stops dispatching
  for everyone → virtuoso's `QXcbEventQueue` starves ("virtuoso main window
  broken") while the DE still renders (kwin composites from its own state) →
  the first interaction that forces kwin to block on Xwayland (dragging an X11
  window) freezes the DE ~0.5 s later.
- The upstream 2018 fix "xwayland: remove dirty window unconditionally on
  unrealize" is already present in 24.1.13 — the circular list here is the
  *core* `miext/damage` pending list, a different structure.

## The fix: patched Xwayland (server-side, no plasma rebuild)

`packages/patched-xwayland.nix` copies the store Xwayland, NOPs the GC
`CopyArea` blit inside `compRestoreWindow` (installed as `damageCopyArea`
by the damage extension), and sanity-runs `Xwayland -version`. The site is
found structurally by `packages/patch-xwayland-comp-restore.py`:

1. read `compRestoreWindow`'s address/size out of `.symtab`
2. NOP the unique GC-ops `CopyArea` call inside that range:
   - x86_64: `ff 50 18` (`call *0x18(%rax)`) -> `90 90 90`
   - aarch64: `ldr xN,[xM,#0x18]` + `blr xN` -> `1f 20 03 d5` (`nop`)

(`+0x18` is the arch-independent `ops->CopyArea` offset in the GC ops
struct; the aarch64 `blr` can be a few instructions after the `ldr`.) No
file offset is baked in, so nixpkgs rebuilds that merely shift the binary
keep working; if the symbols vanish or the pattern stops being unique, the
build fails instead of blind-patching.

For reference, the 24.1.13 sites the finder resolves: x86_64 file/vaddr
0x101c91 (`ff 50 18`); aarch64 0x0fc5c4 (`40 01 3f d6`, `blr x10`). Text
segment maps vaddr to file offset 1:1 on both builds.

`compRestoreWindow` keeps all bookkeeping; only the restore copy is skipped,
which is purely cosmetic in a compositing Wayland session (kwin renders from
its own buffers). With the blit gone, the spin is unreachable from any entry
door — close, minimize, exit, kill, any client.

Both host configs wrap it in `lib.hiPrio` so it shadows the real
`xorg.xwayland` in `/run/current-system/sw/bin`: kwin launches Xwayland via
PATH (verified on both machines: live process argv[0] is the sw path).
**Takes effect after the next login.**

## Session-startup race (historical context)

The circular damage list used to appear (or not) at session startup as a
~50/50 race, so a whole session was either fully well-behaved or froze on the
first close. With the blit bypass the race no longer matters — the traversal
cannot spin.

## RETIRED: client-side workarounds (OUTDATED / UNUSED — do not apply)

Everything below was tried before the root cause was found. It "worked" only
by removing client-issued unmaps, which moved the freeze later (into the
server teardown) instead of fixing it. All of it is reverted on both machines
and the script is stashed in `scripts/attic/patch-libmanager-close-exit.py`.
Kept here for reference only.

Historical apply flow (DO NOT RUN — superseded by the Xwayland fix):

```
cd ~/.cadence/IC251/tools/dfII/bin/64bit
cp libManager.pre-close-exit libManager
cp cdsLibEditor.pre-close-exit cdsLibEditor
~/nixos-config/scripts/attic/patch-libmanager-close-exit.py
```

| binary | function / site | vaddr | file off | old -> new |
|---|---|---|---|---|
| libManager | `cdsLibManager::fileExit` (the `jne`) | 0x5fb508 | 0x1fb508 | `75 0e` -> `90 90` (always quit) |
| libManager | `_qtWinCloser::eventFilter` libSelect-branch `call hide@plt` | 0x71c1f3 | 0x31c1f3 | `e8 98 65 e4 ff` -> `90 90 90 90 90` |
| libManager | `_qtWinCloser::eventFilter` no-MPS-branch `call hide@plt` | 0x71c251 | 0x31c251 | `e8 3a 65 e4 ff` -> `90 90 90 90 90` |
| libManager | `_qtWinCloser::eventFilter` iconify `call showMinimized@plt` | 0x71c2b7 | 0x31c2b7 | `e8 04 58 e4 ff` -> `e8 a4 62 e4 ff` (`call quit@plt` 0x562560) |
| libManager | `cdslibmanExit` `call hide@plt` | 0x71a64a | 0x31a64a | `e8 41 81 e4 ff` -> `90 90 90 90 90` |
| libManager | `killHidden` `call close@plt` | 0x719939 | 0x319939 | `e8 42 ca e4 ff` -> `90 90 90 90 90` |
| cdsLibEditor | `cdsLibEditorExit` (the `je`) | 0x56321e | 0x16321e | `74 08` -> `eb 08` (skip `mainWidget->hide()`) |
| cdsLibEditor | `_qtWinCloser::eventFilter` `call hide@plt` | 0x55726f | 0x15726f | `e8 4c bc f9 ff` -> `90 90 90 90 90` |
| cdsLibEditor | `killHidden` `call close@plt` | 0x5572b7 | 0x1572b7 | `e8 24 e0 f9 ff` -> `90 90 90 90 90` |
| cdsLibEditor | `killHidden` `call hide@plt` | 0x5572f9 | 0x1572f9 | `e8 c2 bb f9 ff` -> `90 90 90 90 90` |
| cdsLibEditor | `cdsLibEditorUnmap` `call hide@plt` | 0x5628dc | 0x1628dc | `e8 df 05 f9 ff` -> `90 90 90 90 90` (dead code, no callers) |
| cdsLibEditor | `cdsLibEditorShutdown` `call hide@plt` | 0x56293c | 0x16293c | `e8 7f 05 f9 ff` -> `90 90 90 90 90` |
| cdsLibEditor | `wrapVoExit` `call hide@plt` | 0x5578dc | 0x1578dc | `e8 df b5 f9 ff` -> `90 90 90 90 90` |
| virtuoso | `XIconifyWindow@plt` | 0x56f7220 | 0x52f7220 | `jmp XDestroyWindow@plt` |
| virtuoso | `XWithdrawWindow@plt` | 0x5710750 | 0x5310750 | `jmp XDestroyWindow@plt` |

Rounds, for the record:

- **Round 1** — `fileExit` always quits (libManager), `cdsLibEditorExit` skips
  its hide, virtuoso's `XIconifyWindow`/`XWithdrawWindow` PLT stubs redirect to
  `XDestroyWindow`. Still froze: `_qtWinCloser::eventFilter` intercepts
  `QEvent::Close` and issues its own unmaps.
- **Round 2** — NOPed the eventFilter hides (libManager ×2, cdsLibEditor ×1)
  and routed the iconify branch to `quit()`. Close became visually clean, but
  the DE still wedged ~0.5 s later: every exit path also ran `hide()`/`close()`
  right before the safe teardown (`delete mainWidget` -> `quit` -> `delete qApp`
  -> `voExit`).
- **Round 3** — NOPed all 7 exit-path hide/close sites (libManager
  `cdslibmanExit` + `killHidden`; cdsLibEditor `killHidden` ×2,
  `cdsLibEditorUnmap`, `cdsLibEditorShutdown`, `wrapVoExit`). Close and exit
  became fully clean client-side — which exposed the real bug: the wedge had
  moved into Xwayland's own teardown (see root cause). That discovery is what
  led to the server-side fix.

Notes from the round-2/3 disassembly (still true, historical):

- `_qtWinCloser::eventFilter` intercepts `QEvent::Close` (type 19) and never
  lets it through. libManager filter at vaddr 0x71c140 (libSelect branch
  `hide()` @0x71c1f3; no-MPS branch `hide()` @0x71c251 before `fileExit`;
  with-MPS branch `showMinimized()` @0x71c2b7 — Cadence's "close = iconify to
  keep the server alive" design). cdsLibEditor filter at vaddr 0x557220 is
  `hide()` + virtual `fileExit` (never `showMinimized`). NOPs (not retargets)
  were required for the hides because `fileExit`/`libSelectCancelSlot` runs on
  the same widget immediately after.
- `_lmgrCloseIconify` @0x71c829 calls `showMinimized` but is gated on the
  `inReplay` flag (QA replay only) — left untouched, like the HiQReplay* sites.
- The Qt side never calls `XIconifyWindow`: the bundled `libcdsQt5XcbQpa.so` is
  pure XCB — minimize = `xcb_send_event` WM_CHANGE_STATE, hide =
  `xcb_unmap_window`.
- In-place rewrites only (no instruction insertion). Non-PIE ELF, x86_64,
  vaddr = file offset + 0x400000. Sizes: libManager 16,440,520 B, cdsLibEditor
  12,600,720 B, virtuoso 818,274,452 B. The `.cdssig` files next to the
  binaries are stale — Cadence does not enforce them.
- A wrong rel32 targets a random address while `--check` still says OK —
  always disassemble patched call sites after applying.
- The timing-perturbation poller (a per-second `pgrep kwin_wayland` +
  `ps -o pcpu=` inside the cadence-env wrapper, since reverted from
  `modules/env/cadence-env.nix`) exploited the Heisenbug — continuous
  observation made closes minimize instead of freeze — and was dropped once
  the real fix landed.

## Backups

- `<name>.pre-close-exit` next to the binaries in
  `~/.cadence/IC251/tools{,.lnx86}/dfII/bin/64bit/` — the clean, unmodified
  originals (byte-verified pristine at every close-exit and qprocess site;
  the retired script's `--revert` restores them). On the macbook these
  backups were taken *after* the qprocess-timeout patch, so they carry the
  launch-delay bytes; on asusg16 they are fully pristine.
- asusg16's intermediate `.pre-close-exit-r2` snapshots were removed
  (2026-09-06).

## Machine state (2026-09-06, verified)

- **asusg16 (x86_64)**: patched Xwayland live (running exe = bypass
  derivation); binaries fully pristine (`--check` 0/6 + 0/7 + 0/2; qprocess
  offsets pristine). User-confirmed working.
- **macbook (aarch64/FEX)**: patched Xwayland live (NOP verified at 0xfc5c4);
  binaries stock close/exit + qprocess launch-delay patch kept (11/11 + 3/3 +
  1/1, ~26 s launch). User-confirmed working.

## Diagnostics (if a freeze ever reappears)

- Capture: `sudo-env -c 'setsid -f bash scripts/capture-kwin-xwayland.sh 15'`
  (single-shot delayed gdb attach to kwin + Xwayland + any Cadence clients →
  `~/.cadence/freeze_dump.log`; needs `sudo-lock` on asusg16). The macbook is
  reachable over `ssh tianyixia@192.168.1.91` while its DE is frozen (sshd
  survives; the frozen DE kills only the local terminal).
- **Heisenbug**: any *continuous* observation (CPU polling, periodic gdb)
  perturbs the race and makes the close minimize instead of freeze. Only
  single-shot delayed capture reproduces it.
- Reading the dump: if Xwayland's main thread is in
  `damageRegionProcessPending`, walk down the stack — if `compRestoreWindow`
  is in it, the Xwayland patch regressed (check `/run/current-system/sw/bin/Xwayland`
  actually resolves to the bypass derivation); if it is *not*, a new door to
  the spin exists — consider the loop guard below.
- **Loop-guard fallback**: a bounded loop in
  `miext/damage/damage.c:damageRegionProcessPending` (aarch64 vaddr 0x11aa00,
  loop advance 0x11aa54 / exit 0x11aa58 on the macbook's binary). Needs
  instruction insertion (the function has no dead space), which is why the
  blit bypass was preferred. Only viable as a Nix derivation on a copied
  binary, same as the current fix.
- Earlier stashed attempts (git history): "do nothing" close
  (`QEvent::ignore()` — stable but the button does nothing), "native close"
  (`mov $1,%eax; ret` — still unmaps, froze), timing poller (see RETIRED).
