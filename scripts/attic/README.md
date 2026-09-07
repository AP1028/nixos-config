# Attic — retired Cadence freeze workarounds

The Xwayland damage-spin freeze is fixed at the root by
`packages/patched-xwayland.nix` (compRestoreWindow blit bypass — see
`docs/handoff.md` for the backtrace-confirmed analysis). These client-side
workarounds are no longer needed on either machine and live here for
reference. They still work if ever needed again.

- **`patch-libmanager-close-exit.py`** — remapped libManager/cdsLibEditor
  close/exit paths (and virtuoso's Xlib iconify/withdraw PLT stubs) to
  quit/destroy so no client-issued unmap could reach the spin. Applied in
  three rounds, then fully reverted on asusg16 (2026-09-06) once the Xwayland
  fix proved out; the pristine `.pre-close-exit` backups live next to the
  binaries in `~/.cadence/IC251/tools{,.lnx86}/dfII/bin/64bit/`.
  `--revert` restores them. The macbook still has the round-1 patches applied
  — revert it (same script, same offsets) after its Xwayland patch is
  confirmed.

- **`handoff.sh`** — dispatcher for the two patch scripts above and
  `../patch-cadence-qprocess-timeout.py`. Superseded: run the qprocess script
  directly (it is still used — it fixes a separate FEX-only launch-delay bug,
  not the freeze).

- **`qtimer-preload/`** — x86_64 LD_PRELOAD interposer that backtraced long
  blocking `ppoll`s in Cadence Qt tools; diagnostic for the launch stall
  (fixed by the qprocess-timeout patch). Kept in case a new stall needs
  pinning.
