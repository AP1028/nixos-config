# Porting Cadence libraries / projects between machines

Applies to the two Cadence machines:

| machine | access | arch | Cadence | install root |
|---|---|---|---|---|
| macbook | local | aarch64 | x86_64 IC25.10 under muvm + box64 (`cadence-env -c '...'`) | `/tools/cadence` |
| asusg16 | `ssh 192.168.1.100` | x86_64 | native IC25.10 | `/tools/cadence` |

Both hosts use the same install root, `/tools/cadence` — the school's exact
layout, on the dedicated `@tools` btrfs subvolume — so paths line up with the
viterbi lab servers (set by `cdsBase` in `modules/env/cadence-env.nix`).
Everything below is written against `<root>`.

Layout under the root (both hosts):

- `<root>/IC251/` — IC25.10 installation
- `<root>/IC251/CDS_GPDK45/` — PDK and std-cell libs:
  `gpdk045_v_5_0`, `gsclib045_svt_mini_v4.4` (contains `GSCLIB045`,
  `gsclib045`, `gsclib045_tech`)
- `<root>/work_gpdk045/` — working directory / "project":
  - `cds.lib` — `include`s the PDK cds.lib files plus
    `DEFINE ee447 <workdir>/ee447`
  - `ee447/` — design library

The `INV` cell currently lives in the vendor library
`gsclib045_svt_mini_v4.4/GSCLIB045/INV/{schematic,maestro}`, with an ADE
`maestro` state in `work_gpdk045/ee447/INV/maestro`.

## How OpenAccess portability works

- OA libraries are architecture-neutral (aarch64 <-> x86_64 is fine).
- Cellviews reference other cells by **library name / cell / view**, not by
  path. Only `cds.lib` (and tool state files) contain paths.
- Therefore: copy the library/cellview directories and make sure every
  library name is `DEFINE`d in the target's `cds.lib`.
- The target OA/IC release must be >= the source release (both here: IC25.1).

## Procedure

Run on the source machine with Virtuoso closed (no open cellviews). `ROOT` is
the install root (`/tools/cadence` on both hosts):

```sh
ROOT=/tools/cadence

# 1. no locks / no running editors
find "$ROOT" -iname '*.cdslck*' -delete

# 2. package (paths relative to the install root), excluding lock files
tar --exclude='*.cdslck*' -czf /tmp/port.tgz -C "$ROOT" \
  IC251/CDS_GPDK45/gsclib045_svt_mini_v4.4/GSCLIB045/INV \
  work_gpdk045/ee447

# 3. ship and unpack at the same relative path on the target
scp /tmp/port.tgz 192.168.1.100:/tmp/port.tgz
ssh 192.168.1.100 'tar xzf /tmp/port.tgz -C /tools/cadence'

# 4. make sure the library name is defined on the target
ssh 192.168.1.100 'grep -q "DEFINE ee447" /tools/cadence/work_gpdk045/cds.lib || \
  echo "DEFINE ee447 /tools/cadence/work_gpdk045/ee447" \
  >> /tools/cadence/work_gpdk045/cds.lib'
```

Then open in Virtuoso (Library Manager) on the target.

For a whole project instead of one cell, tar all of `work_gpdk045` plus any
libraries the design uses:

```sh
tar --exclude='*.cdslck*' -czf /tmp/gpdk45_project.tgz -C "$ROOT" work_gpdk045
```

(GUI alternative: Library Manager -> File -> Export -> Library on the source,
File -> Import -> Library on the target.)

## Notes / gotchas

- Never copy while Virtuoso is running. Quit it cleanly so it removes locks;
  if it was killed (e.g. the muvm tree), delete stale `.cdslck*` files.
- `cds.lib` paths may be `~`-relative or absolute; adjust when the target's
  install root differs — it does now: macbook `/tools/cadence` vs asusg16
  `/tools/cadence` (the PDK `include` lines and `DEFINE ee447`).
- Tech files and DRC/LVS rules bind through the PDK `cds.lib`s; both machines
  already have `CDS_GPDK45` installed identically.
- Vendor libs (e.g. `GSCLIB045`) are writable here; new cells can simply be
  dropped in as directories.

## Record: INV ported macbook -> asusg16 (2026-09-15)

Ported `GSCLIB045/INV` (schematic + maestro) and `work_gpdk045/ee447`
(maestro state); added `DEFINE ee447` to the target `cds.lib`.

## Record: install root moved to /tools/cadence (2026-09-18)

Both hosts now keep the Cadence tree at `/tools/cadence` (the school layout)
instead of `~/.cadence`. Only the root is nix-managed (`cdsBase` in
`modules/env/cadence-env.nix`); the rest is manual and must be redone if
`/tools` is ever rebuilt:

1. **Copy the tree** — same btrfs device, so reflink is instant and shares
   extents (it costs no extra space, and deleting the source afterwards frees
   only metadata, *not* 68G):
   ```sh
   cp -a --reflink=auto ~/.cadence/. /tools/cadence/
   find /tools/cadence -name '*.cdslck*' -delete      # never keep locks
   ```
   Verified faithful: asusg16 587996 files / 8376 symlinks, macbook 408071
   files / 5070 symlinks — equal on both sides. The tool trees are
   relocatable: no runtime file embeds the install root (`cds_root` resolves
   its own path via readlink; `cds.lib` uses
   `$(compute:THIS_TOOL_INST_ROOT)`) — only `iscape_logs` name it.
2. **`~/.cshrc`** (asusg16 only; macbook has no cadence cshrc) —
   `setenv CADHOME /tools/cadence`; everything else derives from it (`CDS`,
   `CDSDIR`, `CDS_LIC_FILE`, `SPECTRE_HOME`). The FHS env's tcsh sources this
   file, so `SPECTRE_HOME` ends up `${CADHOME}/spectre181` exactly as before.
3. **`<root>/bin` wrappers** — both embed the root and are what PATH resolves
   to first (`<root>/bin` leads in the module's profile):
   - `virtuoso` — `cd <root>/work_gpdk045` then
     `exec <root>/IC251/tools/dfII/bin/virtuoso`; this is what
     `cadence-env -c 'virtuoso'` runs. Source of truth is
     `scripts/virtuoso-wrapper.sh`:
     `install -m755 scripts/virtuoso-wrapper.sh <root>/bin/virtuoso`.
   - `iscape` — `ISCAPE_ROOT=<root>/iscape` (drives the LD_PRELOAD of the
     bundled nativemethods lib and the final `iscape.sh` call). Verified with
     `iscape -help`, which locates the tree and falls back to the system JVM
     as the header documents.
4. **`<root>/work_gpdk045/cds.lib`** — PDK `include`s and `DEFINE ee477`
   repointed at the new root.
5. **Repo scripts** that defaulted to the old tree:
   `scripts/virtuoso-wrapper.sh`, `scripts/patch-cadence-qprocess-timeout.py`
   (install root), `scripts/capture-kwin-xwayland.sh` (dump output). The
   QProcess patches live in the tree's binaries, so a reflink copy carries
   them (`--check <root>/IC251` → 11/11, 3/3, 1/1).

Verified on both hosts: `spectre -W` → `sub-version 25.1.0.054`;
`virtuoso -W` → `IC25.1-64b.38`; a DC smoke simulation completed with 0 errors
and checked out `Virtuoso_Spectre` from `<root>/license/license.dat`.

`*.pre-tools-migration` backups sit next to every edited file. Note that
existing ADE/maestro states and generated netlists embed absolute
`~/.cadence/...` paths (PDK model files), so old simulations need re-pointing
— or a temporary `~/.cadence` symlink to `/tools/cadence` — before they can be
re-run.
