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

## REMAINING BLOCKER: ~135s launch (`Virtuoso initialization`)

`cadence-env -c 'virtuoso'` still takes ~135s. Breakdown is consistently
`Virtuoso initialization ~135s + Custom initialization ~2.5s`.

What's actually happening (verified by sampling `/proc/<pid>` of the FEX process):
- virtuoso does only ~8.7s of CPU (`utime`), then **blocks in `ppoll`/`do_poll`
  for ~126s** (`utime` stops advancing). It is a **wait, not translation**.
- During that window the MPS daemons **never come up**: no `cdsNameServer`,
  `cdsMsgServer`, `cdsServIpc`. `clsbd` IS running; `cds_root` spawns and exits
  (a zombie — that part is normal, `cds_root virtuoso` prints the install root
  and returns 0).
- The daemon **binaries/wrappers work when invoked directly**:
  `cdsMsgServer -V`, `cdsNameServer -V`, `cdsServIpc -V`, `cds_root virtuoso` all
  succeed (also via the rootfs-prefixed path). So it's the **spawn path from
  virtuoso**, not the daemons themselves.
- `cdsMsgServer`/`cdsServIpc` link `libmpsc_sh.so`/`libsman_sh.so`
  (in `tools.lnx86/lib/64bit`) — present, and load fine via the wrapper's
  computed `LIBDIR_PATH`.
- virtuoso's own environment is **correct** (CDSBASE/CDS_INST_DIR/OA_HOME/PATH all
  point at `/home/tianyixia/.cadence/IC251/...`).

So the open question is **why virtuoso spawns the MPS daemons but they don't
stay up, and what it is `poll`ing on for 126s**. Not yet identified.

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

Run: `cadence-env -c 'virtuoso'` → currently ~135s, then the GUI works (library
manager still fails with `OA_HOME=/IC251/share/oa` in some runs — related, the
sub-process spawn loses the install root).

Debug tools:
- `fex-crash-diag.patch` + `-e FEX_SILENTLOG=0 -e FEX_OUTPUTLOG=/run/muvm-host/tmp/opencode/fex.log`
  then `kill -11 <pid>` dumps the guest RIP.
- Sample the hang with `/proc/<pid>/stat` (`utime` = CPU), `/proc/<pid>/wchan`,
  `/proc/<pid>/syscall`, and the `comm` of all `/proc/*/` to see which daemons
  are up.

## Files touched (uncommitted)

- `modules/env/cadence-env.nix` — FEX rootfs + `/bin`/`/usr/bin` setup + guest
  script + `sudo -g no-internet` wrapper + `/lib64` tmpfiles + sudo rule.
- `modules/env/fex-fs-segment-store-fix.patch` — Issue 1 fix.
- `modules/env/fex-merged-rootfs.patch` — MergedRootFS + maps + statm/status rewrite.
- `modules/env/fex-tso-disable-gate.patch`, `modules/env/fex-crash-diag.patch`.
- `modules/env/muvm-no-network.patch` — muvm `--no-network` option.
- `hosts/macbook/system/default.nix` — FEX overlay + patches + muvm patch.
- `hosts/macbook/default.nix` — imported `modules/env/no-internet.nix`.
- `~/.cadence/bin/virtuoso` (not in repo) — user wrapper that runs the real
  64-bit binary directly.

NOTE: there are **unrelated concurrent changes** from another agent
(`packages/steam-arm64*`, `modules/packages/steam-arm64.nix`, and the
`steam-arm64` lines in `hosts/macbook/packages/default.nix`) — leave them alone.

## Handoff prompt

```
Continue the Cadence-on-macbook FEX work in ~/nixos-config. Read docs/cadence-fex.md
first. ONE remaining blocker: `cadence-env -c 'virtuoso'` takes ~135s
("Virtuoso initialization ~135s" in the GUI/CDS.log).

Already confirmed (see doc): it is NOT translation — virtuoso does ~8.7s CPU then
blocks in ppoll/do_poll for ~126s; during that window the MPS daemons
(cdsNameServer/cdsMsgServer/cdsServIpc) never come up (clsbd is up; cds_root
spawns+exits normally). The daemon binaries/wrappers themselves work when invoked
directly (cdsMsgServer -V etc.), so the bug is in how virtuoso spawns them.

Next steps:
1. Trace the exact spawn command virtuoso issues for the MPS daemons (instrument
   FEX's ExecveHandler to log path+argv for cds* executables, or run virtuoso with
   FEX_SILENTLOG=0 and grep the fex log). Find why the daemon exits immediately.
2. Identify what virtuoso is poll()ing on (capture /proc/<pid>/syscall args incl.
   the ppoll timeout, and /proc/net/unix + /proc/net/tcp to map the socket peers).
3. Fix the spawn/timeout; re-test with the REAL `cadence-env -c 'virtuoso'` (do not
   trust sh-script measurements — see the test-harness gotcha in the doc: use
   separate `export` statements or the actual cadence-env).

Build/rebuild commands are in the doc. The repo has unrelated steam-arm64 changes
from another agent — leave those files alone. Uncommitted changes are the cadence
work; don't lose them.
```
