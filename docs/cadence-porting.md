# Porting Cadence libraries / projects between machines

Applies to the two Cadence machines:

| machine | access | arch | Cadence |
|---|---|---|---|
| macbook | local | aarch64 | x86_64 IC25.10 under muvm + box64 (`cadence-env -c '...'`) |
| asusg16 | `ssh 192.168.1.76` | x86_64 | native IC25.10 |

Both use the same layout:

- `~/.cadence/IC251/` — IC25.10 installation
- `~/.cadence/IC251/CDS_GPDK45/` — PDK and std-cell libs:
  `gpdk045_v_5_0`, `gsclib045_svt_mini_v4.4` (contains `GSCLIB045`,
  `gsclib045`, `gsclib045_tech`)
- `~/.cadence/work_gpdk045/` — working directory / "project":
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

Run on the source machine with Virtuoso closed (no open cellviews):

```sh
# 1. no locks / no running editors
find ~/.cadence -iname '*.cdslck*' -delete

# 2. package (paths relative to ~/.cadence), excluding lock files
tar --exclude='*.cdslck*' -czf /tmp/port.tgz -C ~/.cadence \
  IC251/CDS_GPDK45/gsclib045_svt_mini_v4.4/GSCLIB045/INV \
  work_gpdk045/ee447

# 3. ship and unpack at the same relative path on the target
scp /tmp/port.tgz 192.168.1.76:/tmp/port.tgz
ssh 192.168.1.76 'tar xzf /tmp/port.tgz -C ~/.cadence'

# 4. make sure the library name is defined on the target
ssh 192.168.1.76 'grep -q "DEFINE ee447" ~/.cadence/work_gpdk045/cds.lib || \
  echo "DEFINE ee447 /home/tianyixia/.cadence/work_gpdk045/ee447" \
  >> ~/.cadence/work_gpdk045/cds.lib'
```

Then open in Virtuoso (Library Manager) on the target.

For a whole project instead of one cell, tar all of `work_gpdk045` plus any
libraries the design uses:

```sh
tar --exclude='*.cdslck*' -czf /tmp/gpdk45_project.tgz -C ~/.cadence work_gpdk045
```

(GUI alternative: Library Manager -> File -> Export -> Library on the source,
File -> Import -> Library on the target.)

## Notes / gotchas

- Never copy while Virtuoso is running. Quit it cleanly so it removes locks;
  if it was killed (e.g. the muvm tree), delete stale `.cdslck*` files.
- `cds.lib` paths may be `~`-relative or absolute; adjust if the target user
  or home differs (here both are `/home/tianyixia`).
- Tech files and DRC/LVS rules bind through the PDK `cds.lib`s; both machines
  already have `CDS_GPDK45` installed identically.
- Vendor libs (e.g. `GSCLIB045`) are writable here; new cells can simply be
  dropped in as directories.

## Record: INV ported macbook -> asusg16 (2026-09-15)

Ported `GSCLIB045/INV` (schematic + maestro) and `work_gpdk045/ee447`
(maestro state); added `DEFINE ee447` to the target `cds.lib`.
