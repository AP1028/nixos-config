# Cadence (virtuoso) on macbook via FEX-in-muvm — status & handoff

Goal: run Cadence IC25.1 `virtuoso` (x86_64) on the **macbook** (Apple Silicon,
aarch64, **16K-page kernel**) by emulating x86_64 with FEX.

The host kernel is 16K pages; FEX requires 4K pages, so FEX runs **inside a
muvm microVM** (whose libkrunfw guest kernel is 4K-page). `box64` is not used
for Cadence (that was an earlier approach); the current path is FEX.

## Architecture

```
cadence-env -c 'virtuoso'
  └─ muvm -f <fex-cadence-rootfs> -m -e DISPLAY -e XAUTHORITY -- <cadence-env-guest> "$@"
       └─ inside VM: guest script sets env → exec tcsh -c 'virtuoso'
            └─ tcsh runs ~/.cadence/bin/virtuoso (first on PATH)
                 └─ ~/.cadence/bin/virtuoso sets Cadence LD_LIBRARY_PATH → exec
                    IC251/tools.lnx86/dfII/bin/64bit/virtuoso  (real x86_64 ELF)
```

Key components (all in `modules/env/cadence-env.nix`):

- `fex-cadence-rootfs` — an erofs image of the x86_64 userspace: all system
  libs symlinked into `/usr/lib64` (from `x86 = pkgs.pkgsCross.gnu64`),
  `ld-linux-x86-64.so.2` at `/lib64`, aarch64 `ksh`/`tcsh`/`bash`/`sh` in
  `/bin`, plus SLES12 SONAME compat symlinks. `libc.so.6` is a **real file**
  copy (not a symlink) — see "saSecurity" below.
- `cadence-env-guest` — the in-VM profile script (exports CDSBASE/CDS_INST_DIR/
  OA_HOME/VSM_* /CDS_LIC_* + `LD_LIBRARY_PATH=/usr/lib64:/lib64`, prepends
  `~/.cadence/bin` to PATH), then `exec tcsh "$@"`.
- `cadence-env` (aarch64 branch) — `muvm -f <rootfs> -m -e DISPLAY -e XAUTHORITY
  -- <guest> "$@"`.

Overlay in `hosts/macbook/system/default.nix` pins FEX 2608 (jemalloc LG_PAGE
16K fix + `FEXInterpreter` symlink) and applies
`modules/env/fex-fs-segment-store-fix.patch`.

`~/.cadence/bin/virtuoso` (user file, not in repo) was rewritten to run the
real 64-bit binary directly (the ksh `cdnWrapperWithOA` launcher can't run in
the VM: `/bin` is read-only there, no `/bin/ksh`).

## What already works

1. FEX runs x86_64 inside muvm (validated with an x86_64 bash printing a string).
2. The real `virtuoso` binary **fully loads** every library under FEX — all
   Cadence libs + system libs resolve. This required the exact asusg16
   `LD_LIBRARY_PATH` (below) plus adding missing x86_64 system libs to the
   rootfs (libxcrypt-legacy/libcrypt.so.1, libuuid, libelf, systemd,
   libxkbcommon, xcbutil*, pciutils, libidn2, libssh, openblas/lapack/blas/
   gfortran — see `fexExtraX86LibPkgs`).
3. The FS/GS segment bug is **fixed** (patch below).

## Issue 1 (FIXED): FEX dropped FS/GS base on vector memory stores

Symptom: virtuoso segfaulted (SIGSEGV) during startup, `si_addr=-0x2ae0`
(a NULL-ish negative address), inside Cadence's obfuscated saSecurity/VSM TLS
code (`movd %xmm0, %fs:-0x2ae0`).

Root cause: `OpDispatchBuilder::MOVBetweenGPR_FPR` (and the MOVNT/AVX-128
equivalents) computed a memory-store address with
`LoadSourceGPR(..., {.LoadData=false})`, which returns the address **without**
the segment base (`LoadEffectiveAddress` is called with `AddSegmentBase=false`).
FS-relative stores therefore ignored `fs_cached` → `0 - 0x2ae0`.

Fix (`modules/env/fex-fs-segment-store-fix.patch`): wrap the address with
`AppendSegmentOffset(..., Op->Flags)` in 4 sites:
- `Vector.cpp` `MOVVectorNTOp` (MOVNT*)
- `Vector.cpp` `MOVBetweenGPR_FPR` (MOVD/MOVQ)
- `AVX_128.cpp` `AVX128_MOVVectorNT`
- `AVX_128.cpp` `AVX128_MOVBetweenGPR_FPR`

(The load path already goes through `LoadSourceFPR → DecodeAddress → A.Segment`,
so only stores were wrong. XADD already does `AppendSegmentOffset`.)

## Issue 2 (ROOT CAUSE KNOWN, NOT FIXED): saSecurity "Failed to initialize"

Symptom (current): `cadence-env -c 'virtuoso'` prints
`Error: Received an unexpected system exception: Failed to initialize saSecurity.`

This is **not** the license checkout — it's saSecurity's anti-tamper env check,
reverse-engineered by a previous agent (quoted below):

> saSecurity opens `/proc/self/maps`, parses every line, and requires the libc
> mapping's path to **start with** `/usr/lib64/libc-` or `/lib64/libc-*`. On
> NixOS the loader resolves libc to a `/nix/store/...` path → treated as
> tampering → throw. Fix on box64: copy the real glibc `libc.so.6` as a real
> file over `/usr/lib64/libc.so.6` (a symlink resolves to the store path in
> maps; a real file records `/usr/lib64/libc.so.6`), and start LD_LIBRARY_PATH
> with `/usr/lib64`.

The env-vars gate (`CDS_LIC_USE_AGENT=0`, `VSM_FWK=VSM95011`, `VSM_ITK=VSM12141`)
is already set in the guest script, and the `cds-apr` libm fix is already in the
rootfs. The remaining blocker is the libc path.

**Why the box64 fix doesn't carry over:** under FEX the rootfs is mounted at
`/run/fex-emu/rootfs` and FEX **prefixes** guest paths with it. The libc maps as:

```
/run/fex-emu/rootfs/usr/lib64/libc.so.6     (after copying real libc.so.6)
```

not `/usr/lib64/libc.so.6`. The `/run/fex-emu/rootfs` prefix breaks saSecurity's
`/usr/lib64/libc-` prefix check. (I copied the real `libc.so.6` into the rootfs
already; it changes the maps from `/nix/store/...` to the erofs path, which is
closer but still prefixed.)

**Fix direction:** make the libc path in `/proc/self/maps` be `/usr/lib64/...`.
muvm's `-m` merged-rootfs mode writes `{"Config":{"RootFS":..., "MergedRootFS":"1"}}`
into FEX's Config.json, but **FEX 2608 does not implement `MergedRootFS`** (it
logs `Unknown configuration option 'MergedRootFS'` and ignores it). So FEX treats
the overlay as a normal prefix rootfs. Options:
- Backport `MergedRootFS` into FEX 2608 (chroot/pivot into `/run/fex-emu/rootfs`
  instead of prefixing), or
- Bump FEX to a version that has it (2608 is the latest tag; check `main`).

## Issue 3 (UNRESOLVED): boost::serialization spin

When running the binary **directly** (not via `~/.cadence/bin/virtuoso`), with
`LD_LIBRARY_PATH` starting with `/usr/lib64:/lib64`, virtuoso gets **past**
saSecurity and then **spins** (State=R, wchan=0, userspace busy-loop) in
`boost::serialization::typeid_system::extended_type_info_typeid_0` at guest
`rip=0xd0d1f60` (offset `0xccd1f60` in the binary) — C++ static-init
(`type_register` walking a `std::multiset`, uses `__cxa_guard_acquire` atomics).
This is a FEX bug (the box64 path completed static init and reached the license
checkout). Untested hypothesis: the muvm guest's hardware TSO
(`PR_SET_MEM_MODEL_TSO`) is accepted but broken, corrupting the guard atomics
(FEX then disables its software TSO atomics). I added an
`FEX_DISABLE_HARDWARE_TSO` gate in `FEXInterpreter.cpp` `SetupTSOEmulation` to
force software TSO but the test was inconclusive (the env var may not have
reached FEX). Worth re-testing cleanly.

## Key facts / reproduction

Exact asusg16 Cadence `LD_LIBRARY_PATH` (from `virtuoso -debug3264`):

```
$IC/share/oa/lib/lnx86/opt:$IC/tools.lnx86/lib/64bit:$IC/tools.lnx86/lib:$IC/tools.lnx86/sev/lib/64bit:$IC/tools.lnx86/hdf5/lib/64bit:$IC/tools.lnx86/lz4/lib/64bit:$IC/tools.lnx86/python/64bit/lib:$IC/tools.lnx86/TPtools/grpc/lib64:$IC/tools.lnx86/TPtools/boost/lib/64bit:$IC/tools.lnx86/extraction/lib/64bit:$IC/tools.lnx86/leveldb/lib/64bit:$IC/tools.lnx86/Qt/v5/64bit/lib
```
(plus `/usr/lib64:/lib64` for the FEX system libs). `IC = ~/.cadence/IC251`;
`share/oa -> ../oa_v22.62.009`.

Build (no system rebuild needed):
```
nix eval --impure --accept-flake-config ~/nixos-config#nixosConfigurations.macbook.config.environment.systemPackages \
  | grep -oE '/nix/store/[a-z0-9]+-cadence-env\.drv' | head -1   # then
nix-store --realise <that .drv>
```

Run:
```
cadence-env -c 'virtuoso'
```
Expected today: `Failed to initialize saSecurity.` (Issue 2).

Debug FEX via a signal dump (guest RIP on SIGSEGV): the earlier diagnostic was a
patch to `SignalDelegator.cpp` `HandleSignal` calling `SpillSRA(...)` then
`LogMan::Msg::EFmt("[FEX-CRASH] ... rip=... host_pc=...")`; run with
`-e FEX_SILENTLOG=0 -e FEX_OUTPUTLOG=/run/muvm-host/tmp/opencode/fex.log`, let it
spin, then `kill -11 <pid>`. (The guest is FEX's process; `/tmp` is shared.)

## Files touched (uncommitted as of handoff)

- `modules/env/cadence-env.nix` — FEX rootfs + guest script + muvm wrapper
- `modules/env/fex-fs-segment-store-fix.patch` — Issue 1 fix
- `hosts/macbook/system/default.nix` — fex overlay (FEX 2608 + patch)
- `hosts/macbook/packages/default.nix` — unrelated wechat-uos desktop-fix wrap
  (keep; from another agent)
- `~/.cadence/bin/virtuoso` (not in repo) — user wrapper that runs the real
  binary directly

## Notes

- The overlay `patches` uses an **absolute** path
  `/home/tianyixia/nixos-config/modules/env/fex-fs-segment-store-fix.patch`
  because a relative `../` path resolved against the FEX source, not the nix
  file. Fragile if the repo moves.
- `muvm` bundles `fex` in its wrapper PATH; rebuilding `fex` rebuilds `muvm` +
  `cadence-env`.
- The VM's `/bin` is read-only (only `sh -> bash-interactive`), so Cadence's ksh
  launchers (`#!/bin/ksh`) and its crash tools (`cdsPstack` needs
  `/bin/ls`,`/usr/bin/wc`,`/bin/sed`; `cdsCrashReport` needs `/bin/ksh`) can't
  run there. The real binary runs directly, so this is only cosmetic for the
  crash-report tooling.

## Handoff prompt

```
Continue the Cadence-on-macbook FEX work in ~/nixos-config (docs/cadence-fex.md
has the full writeup). Two open items:

1. saSecurity "Failed to initialize saSecurity" (the blocker): saSecurity
   requires the libc mapping in /proc/self/maps to start with /usr/lib64/libc-
   or /lib64/libc-*. Under FEX it maps as /run/fex-emu/rootfs/usr/lib64/libc.so.6
   (FEX prefixes guest paths with the rootfs). muvm writes a MergedRootFS config
   but FEX 2608 ignores it ("Unknown configuration option 'MergedRootFS'").
   Implement/backport MergedRootFS in FEX (chroot/pivot into the overlay) so the
   libc path becomes /usr/lib64/libc.so.6, or bump FEX past 2608 if main has it.

2. boost::serialization spin (when running the binary directly): guest
   rip=0xd0d1f60, static-init type_register. Try re-testing the
   FEX_DISABLE_HARDWARE_TSO=1 hypothesis (hardware TSO in the muvm guest may be
   broken); the env var gate exists in FEXInterpreter.cpp SetupTSOEmulation but
   needs to reach FEX inside the VM.

Build with: nix eval …#nixosConfigurations.macbook.config.environment.systemPackages
| grep cadence-env.drv, then nix-store --realise. Run: cadence-env -c 'virtuoso'.
Use the SIGSEGV signal-dump trick in the doc for FEX debugging.
```
