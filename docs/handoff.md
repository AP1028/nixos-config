# Handoff: Xwayland DE freeze on Cadence close/minimize

Status: **client-side remap complete, awaiting manual verification**. The DE
freezes (Xwayland damage-extension spin) when a Cadence window is
minimized / closed / exited. All known close paths in all three client binaries
(virtuoso, libManager, cdsLibEditor) are now remapped to quit/destroy; the
remaining work is testing across fresh launches on asusg16 (x86_64) and macbook
(aarch64/FEX).

## Root cause (confirmed)

Xwayland's damage extension spins in `damageRegionProcessPending` because a
`pDamage->pNext` list becomes **circular**. Trigger path on window **unmap**:

```
UnmapWindow -> compUnrealizeWindow -> compCheckRedirect -> compRestoreWindow
            -> damageCopyArea -> damageRegionProcessPending   (infinite spin)
```

The **destroy** path (`compDestroyWindow`) does NOT do that restore, so
destroy/quit is safe while unmap/minimize is not. (Source:
`/tmp/opencode/xw-src-dir/xwayland-24.1.13/composite/compwindow.c`,
`composite/compalloc.c`, `miext/damage/damage.c`.)

This bug class is known upstream (Xwayland/compositor 100% CPU livelocks):
sway#5859, sway#6974, KDE bug 442846. No canonical upstream fix for the
circular-list spin surfaced; Xwayland's `-extension DAMAGE` kill-switch was
considered and rejected (kwin spawns Xwayland itself and needs DAMAGE for X11
repaint tracking; injecting the arg means kwin-side hacks).

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

Disassembly of the exit flow found them: `cdslibmanExit` does
`mainWidget->hide()` (0x71a64a) **before** its teardown, and every exit route
ends in the same safe sequence: `delete mainWidget` -> `quit()` -> `delete
qApp` -> `voExit` (each widget delete = one `xcb_destroy_window`, the
individually-destroyed kind that does not spin, then a **windowless**
connection close). Round 3 NOPs every hide/close on the exit paths of both
binaries (7 sites above), so only the safe sequence remains.

If a freeze STILL occurs after round 3, the remaining suspects are the
connection-close teardown of non-widget resources, or `endAllBusy`'s
`XUnmapWindow` on the libSelect busy-shield (0x6930d3, libSelect paths only) —
capture the backtrace (below) before patching further.

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
  legitimate without FEX). Round-3 not yet field-tested.
- **macbook (aarch64/FEX)**: round-1 sites applied; needs `git pull` then
  `./scripts/handoff.sh apply` for the new eventFilter + exit-path sites
  (offsets are identical — both machines run the same x86_64 binaries), then
  its usual qprocess patch.

## Manual test checklist (both machines, after a fresh login)

Arm the freeze-dump capture FIRST so a repro costs us nothing: it sleeps, then
attaches gdb once to kwin + Xwayland and dumps both stacks to
`~/.cadence/freeze_dump.log` (single delayed attach — continuous observation
perturbs the bug):

```
sudo-env -c 'setsid -f bash ~/nixos-config/scripts/capture-kwin-xwayland.sh 15'
# now close the libManager window within 15s
```

1. Fresh login first (re-rolls the ~50/50 session race); repeat a few times.
2. virtuoso -> Library Manager -> click X: expect process exits
   (`pgrep libManager` empty), no freeze; reopening Library Manager respawns it.
3. cdsLibEditor: click X: quit flow, no freeze.
4. File->Exit on both: same expectation (shares the exit path).
5. Titlebar **minimize** on both: kwin-initiated unmap may be unreachable by
   client patching — if this freezes, record it.
6. If anything freezes: `~/.cadence/freeze_dump.log` has the backtraces —
   check which function spins in Xwayland (`damageRegionProcessPending` vs
   something else) and send it over.

## Tried and stashed (git history)

- **"do nothing" close** — `andb $0xfb,0x12(%event)` (= `QEvent::ignore()`;
  `m_accept` is bit 2 at offset 0x12 in Qt 5.15) so the X button is a no-op.
  *Stable* (no unmap), but the close button does nothing. libManager
  `_qtWinCloser::eventFilter` off `0x31c150`, cdsLibEditor `closeEvent` off `0x139210`.
- **"native close"** — `mov $1,%eax; ret` in the filter (return true). Still unmaps -> freezes.
- **timing poller** — per-second `pgrep kwin_wayland` + `ps -o pcpu=`. "Works by chance", not reliable. Disabled.

## The deterministic fix (BLOCKED)

A loop guard in `miext/damage/damage.c:damageRegionProcessPending`
(AArch64 `Xwayland` vaddr `0x11aa00`, loop advance `0x11aa54` / exit `0x11aa58`).
Blockers:

1. **Source patch via Nix overlay** -> rebuilds the whole plasma/KDE stack (unacceptable; plasma is a flake-updated moving target).
2. **Binary patch of the installed Xwayland** -> `/nix/store` is read-only.
3. **Loop bound needs a counter register** (x21, callee-saved, unsaved in the prologue) -> requires instruction insertion, and the function has no dead space (the only slack is the epilogue's register-zeroing `mov xN,#0` block).

## Handoff script

`scripts/handoff.sh` wraps both patch scripts: `apply` (default), `check`,
`revert`. It runs the qprocess/launch-delay script **only on aarch64** and
skips it with a notice elsewhere. Run `./scripts/handoff.sh check` to confirm
the on-disk state.
