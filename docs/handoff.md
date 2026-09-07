# Handoff: Xwayland DE freeze on Cadence close/minimize

Status: **root cause confirmed by backtrace; server-side fix deployed on
asusg16, pending relogin verification**. The DE freezes (Xwayland
damage-extension spin) when libManager disconnects; virtuoso going
unresponsive right after a clean close is the same wedge. The client-side
patch set (below) is kept, and a patched Xwayland
(`packages/patched-xwayland.nix`) removes the spin itself.

## Root cause (confirmed by gdb backtrace, 2026-09-06)

Captured live with `scripts/capture-kwin-xwayland.sh` while the DE was
wedged (`~/.cadence/freeze_dump.log`). Xwayland's single dispatch thread
spins inside the teardown of the just-disconnected libManager client:

```
CloseDownClient -> FreeClientResources -> doFreeResource -> DeleteWindow
  -> UnmapWindow -> UnrealizeTree -> compUnrealizeWindow -> compCheckRedirect
  -> compRestoreWindow -> damageCopyArea -> damageRegionProcessPending  (spin)
```

Corrections to earlier assumptions this proves:

- **Destroy is NOT safe in xwayland-24.1.13**: `DeleteWindow` itself goes
  through `UnmapWindow -> compRestoreWindow`. The macbook-era "destroy path
  does not restore" note is wrong for this build. Any client exit frees its
  windows server-side; nothing client-side can prevent it.
- The damage chain is corrupted on **libManager's own windows**, created by
  the graceful shutdown path: killing libManager externally (wrapper pkill at
  virtuoso exit) tears the same windows down cleanly, while quitting from the
  X button/File→Exit wedges. Mechanism unknown (an Xwayland bookkeeping bug;
  the clients do not even use the X Damage extension). On real X11 there is
  no composite-restore-unmap path, which is why X11 never froze.
- Symptom mapping: the wedge starts at disconnect -> Xwayland stops
  dispatching for everyone -> virtuoso's `QXcbEventQueue` starves ("virtuoso
  main window broken") while the DE still renders (kwin composites from its
  own state) -> the first interaction that forces kwin to block on Xwayland
  (dragging an X11 window) freezes the DE ~0.5 s later. "libmanager closes
  fine, virtuoso breaks, xwayland breaks on interact" is exactly this.

The original unmap triggers (iconify on close, hide at exit) spin through the
same `compRestoreWindow -> damageCopyArea -> damageRegionProcessPending`
stack - it is one bug with three entry doors, which is why each client-side
round only moved the freeze later.

## The fix: patched Xwayland (server-side, no plasma rebuild)

`packages/patched-xwayland.nix` copies the store Xwayland (24.1.13, 2.9 MB),
NOPs the 3-byte GC CopyArea blit inside `compRestoreWindow`
(`call *0x18(%rax)` = `ff 50 18` at file offset **0x101c91**; the text
segment maps vaddr to file offset 1:1), and sanity-runs `Xwayland -version`.
The build byte-checks first: a nixpkgs bump that shifts the binary fails the
build instead of blind-patching.

`compRestoreWindow` keeps all bookkeeping; only the restore copy is skipped,
which is purely cosmetic in a compositing Wayland session (kwin renders from
its own buffers). With the blit gone, the spin is unreachable from any entry
door - close, minimize, exit, kill, any client.

Installed on asusg16 wrapped in `lib.hiPrio` so it shadows the real
`xorg.xwayland` in `/run/current-system/sw/bin`: kwin launches Xwayland via
PATH (verified: live process argv[0] is `/run/current-system/sw/bin/Xwayland`).
**Takes effect after the next login.** For the macbook (aarch64/muvm), apply
the same compRestoreWindow-blit bypass to its Xwayland - nm-guided, offsets
differ from x86_64.

## Launch-dependence (key observation)

The circular list is created (or not) at **session startup** as a ~50/50 race, so
a whole session is either fully well-behaved or freezes on the **first** close.
It is not a per-close coin flip. Test after a **fresh login**, several times.

## Client patches (complete set)

`scripts/patch-libmanager-close-exit.py` (apply / `--check` / `--revert`).
Recommended flow: restore the pristine copies, then apply everything in one
pass on top of the fresh binaries (never patch on top of unknown state):

```
cd ~/.cadence/IC251/tools/dfII/bin/64bit
cp libManager.pre-close-exit libManager
cp cdsLibEditor.pre-close-exit cdsLibEditor
~/nixos-config/scripts/patch-libmanager-close-exit.py
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

## Teardown ALSO spins (round 3, 2026-09-06 testing)

Testing on asusg16 showed the round-2 state still froze: X button -> window
closes -> ~0.5 s later the DE freezes (Xwayland thread pegged). Crucially,
**File->Exit on the UNPATCHED binary freezes the same way** — so it was never
an unmap-at-click problem only: the quit/exit path itself contained unmaps.
The X button was (deliberately) routed to `quit()`, i.e. the same path as
File->Exit, hence the identical signature.

Round 3 NOPed every hide/close on the exit paths of both binaries (7 sites in
the table above), which made the close itself clean — and exposed the real
bug: the wedge had merely moved into the server-side teardown (see the
confirmed root cause above). The gdb capture that nailed it is the
`capture-kwin-xwayland.sh` flow documented in the test checklist.

All are in-place rewrites (no instruction insertion). Non-PIE ELF, x86_64,
vaddr = file offset + 0x400000. Sizes: libManager 16,440,520 B, cdsLibEditor
12,600,720 B, virtuoso 818,274,452 B. The `.cdssig` files next to the binaries
are stale — Cadence does not enforce them.

### Why these sites (disassembly findings, 2026-09-06)

`_qtWinCloser::eventFilter` intercepts `QEvent::Close` (type 19) on the main
window and never lets it through:

- **libManager** (filter at vaddr 0x71c140): three freeze paths —
  libSelect branch `hide()` @0x71c1f3; no-MPS-clients branch `hide()` @0x71c251
  before `fileExit` (patched to always quit); with-MPS-clients branch
  `showMinimized()` @0x71c2b7 (the "close = iconify to keep the server alive"
  behavior). NOPing the hides is required — `fileExit` /
  `libSelectCancelSlot` is called on the same widget immediately after, so a
  `deleteLater` there would be a use-after-free. The iconify branch now calls
  `QCoreApplication::quit()`: close-with-clients = process exit, all windows
  destroyed via the X connection close (the safe destroy path); Cadence tools
  respawn libManager on next use (fast on native x86).
- **cdsLibEditor** (filter at vaddr 0x557220): the X button is
  `hide()` @0x55726f + virtual `cdsLibEditor::fileExit` — **not**
  `showMinimized()` as earlier assumed on the macbook. NOP the hide and the
  close path becomes the same quit flow as File→Exit.
- `_lmgrCloseIconify` @0x71c829 also calls `showMinimized`, but it is gated on
  the `inReplay` flag (QA replay only) — intentionally left untouched, like the
  HiQReplay* call sites.
- The Qt side never calls `XIconifyWindow`: the bundled
  `libcdsQt5XcbQpa.so` is pure XCB — minimize = `xcb_send_event` WM_CHANGE_STATE,
  hide = `xcb_unmap_window`. Both land in the server-side unmap path; only a
  real destroy avoids the spin. Patching the Qt plugin is not an option (it
  would break every hide in every Cadence Qt app).

### Backups

- `<name>.pre-close-exit` — the **clean, unmodified originals** (byte-verified
  pristine at every close-exit and qprocess site; `--revert` restores them).
  Never patch on top of anything else — restore from these first.
- `<name>.pre-close-exit-r2` — asusg16-only snapshot of the intermediate
  round-1 state, kept as a rollback point; safe to delete once the full set is
  verified.

## Machine state

- **asusg16 (x86_64)**: all 15 sites applied from pristine (verified with
  `--check` + objdump disassembly of every patched call). qprocess-timeout
  patch **pristine** — it is FEX/macbook-only and `scripts/handoff.sh` now
  skips it on non-aarch64 by design (the 30s retry loop it shortens is
  legitimate without FEX). Round-3 field-tested: close is clean, wedge moved
  to the server teardown (see root cause) -> patched Xwayland installed,
  takes effect after the next login.
- **macbook (aarch64/FEX)**: round-1 sites applied; needs `git pull` then
  `./scripts/handoff.sh apply` for the new eventFilter + exit-path sites
  (offsets are identical — both machines run the same x86_64 binaries), then
  its usual qprocess patch. The Xwayland blit bypass needs its own aarch64
  offsets (nm-guided, same method as `packages/patched-xwayland.nix`).

## Manual test checklist (after the next login — patched Xwayland active)

The patched Xwayland is only picked up when kwin spawns a new session, so
**log out and back in first**. Then, in any session state (the ~50/50 race no
longer matters for the freeze — the blit it spins in is gone):

1. virtuoso -> Library Manager -> click X: process exits, window closes, and
   crucially virtuoso stays responsive afterwards (the old tell was virtuoso
   freezing the moment LM closed).
2. Drag the virtuoso main window: was the freeze trigger — should be smooth.
3. Titlebar minimize on LM/virtuoso: the last unfixed unmap path, now also
   under the bypass.
4. cdsLibEditor X button and File->Exit on both: clean quit, no hang.
5. Keep `scripts/capture-kwin-xwayland.sh` in reserve: arm it before a
   suspicious close; if a wedge ever reappears, `~/.cadence/freeze_dump.log`
   will show whether the spin still passes through `compRestoreWindow`
   (it should not) or found a new door (loop-guard fallback, see below).

## Tried and stashed (git history)

- **"do nothing" close** — `andb $0xfb,0x12(%event)` (= `QEvent::ignore()`;
  `m_accept` is bit 2 at offset 0x12 in Qt 5.15) so the X button is a no-op.
  *Stable* (no unmap), but the close button does nothing. libManager
  `_qtWinCloser::eventFilter` off `0x31c150`, cdsLibEditor `closeEvent` off `0x139210`.
- **"native close"** — `mov $1,%eax; ret` in the filter (return true). Still unmaps -> freezes.
- **timing poller** — per-second `pgrep kwin_wayland` + `ps -o pcpu=`. "Works by chance", not reliable. Disabled.

## The loop-guard Xwayland patch (superseded, kept for history)

The macbook-era plan was a loop guard in
`miext/damage/damage.c:damageRegionProcessPending` (AArch64 vaddr `0x11aa00`,
loop advance `0x11aa54` / exit `0x11aa58`), abandoned because:

1. **Source patch via Nix overlay** -> rebuilds the whole plasma/KDE stack (unacceptable; plasma is a flake-updated moving target).
2. **Binary patch of the installed Xwayland** -> `/nix/store` is read-only.
3. **Loop bound needs a counter register** (x21, callee-saved, unsaved in the prologue) -> requires instruction insertion, and the function has no dead space (the only slack is the epilogue's register-zeroing `mov xN,#0` block).

All three blockers evaporate with the compRestoreWindow-blit bypass: the copy
is a plain derivation (no store writes), `lib.hiPrio` shadowing replaces the
overlay, and it is a 3-byte NOP — no instruction insertion. Keep the loop
guard as the fallback if some future freeze shows a spin that does NOT pass
through `compRestoreWindow`.

## Handoff script

`scripts/handoff.sh` wraps both patch scripts: `apply` (default), `check`,
`revert`. It runs the qprocess/launch-delay script **only on aarch64** and
skips it with a notice elsewhere. Run `./scripts/handoff.sh check` to confirm
the on-disk state.
