# Handoff: Xwayland DE freeze on Cadence close/minimize

Status: **UNRESOLVED**. The DE freezes (Xwayland damage-extension spin) when a
Cadence window is minimized / closed / exited.

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

## Launch-dependence (key observation)

The circular list is created (or not) at **session startup** as a ~50/50 race, so
a whole session is either fully well-behaved or freezes on the **first** libManager
close. It is not a per-close coin flip.

## Current client patches — NOT 100%, launch-dependent 50/50

`scripts/patch-libmanager-close-exit.py` (apply / `--check` / `--revert`):

| binary | function / site | vaddr | file off | patch |
|---|---|---|---|---|
| libManager | `cdsLibManager::fileExit` (the `jne`) | 0x5fb508 | 0x1fb508 | `75 0e` -> `90 90` (always quit) |
| cdsLibEditor | `cdsLibEditorExit` (the `je`) | 0x56321e | 0x16321e | `74 08` -> `eb 08` (skip `mainWidget->hide()`) |
| virtuoso | `XIconifyWindow@plt` | 0x56f7220 | 0x52f7220 | `jmp XDestroyWindow@plt` |
| virtuoso | `XWithdrawWindow@plt` | 0x5710750 | 0x5310750 | `jmp XDestroyWindow@plt` |

Backups are `<name>.pre-close-exit` next to each binary (restored by `--revert`).
Binary sizes: libManager 16,440,520 B, cdsLibEditor 12,600,720 B, virtuoso ~115 MB
(non-PIE ELF, offsets re-verified against the exact IC25.1 install).

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

## Also applied (unrelated — keep)

`scripts/patch-cadence-qprocess-timeout.py` — aarch64 launch-delay fix
(`0x7530`->`0x7d0`: virtuoso 11 sites, libManager 3, libcdsQt5Core 1). Backups
`<name>.pre-qprocess-timeout`.

## Handoff script

`scripts/handoff.sh` wraps both patch scripts: `apply` (default), `check`,
`revert`. Run `./scripts/handoff.sh check` to confirm the on-disk state.
