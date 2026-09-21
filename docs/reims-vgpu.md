# Reims vGPU on asusg16

Reims vGPU (`github:steelbrain/reims-vgpu`) is an alpha research project that
gives an **unmodified macOS guest** accelerated graphics under QEMU. macOS
ships the driver itself (`AppleParavirtGPU.kext`); this project provides the
QEMU device that driver binds to and executes the guest's GPU command stream
through Vulkan on the host. Nothing is installed in the guest.

This document records what is packaged in this repo, what was set up by hand,
and what remains imperative.

## What is packaged, and what is not

| Piece | Where it lives | Built by |
|---|---|---|
| `qemu-system-x86_64` (QEMU fork + `reims-vgpu-pci` device, Rust staticlib linked in, Vulkan backend) | nix store | `packages/reims-vgpu/default.nix` |
| `reims-vgpu-gop.rom` (UEFI GOP PCI option ROM) | nix store | same file |
| `reims-vgpu-boot` (wrapper around upstream `vm/boot-x86.sh`) | nix store | same file |
| macOS guest disk, OpenCore, OVMF vars, snapshot rails, logs | `~/reims-vgpu/vm/` (mutable, never in the store) | OSX-KVM + the boot harness |
| OSX-KVM provisioning clone | `~/OSX-KVM/` | manual |

The upstream project has **no packaging**: `vm/boot-x86.sh` is written to be
run from a git clone and rebuilds both the QEMU fork and the option ROM on
every boot. The package turns those two build steps into pinned derivations
and patches a store copy of the boot script so it uses them instead:

- `QEMU_BIN_DEFAULT` → the store QEMU,
- `_reims_vgpu_gop_default` → the store ROM,
- the `ensure_rust_tools` / `build_reims_vgpu_efi` calls → `:` (no cargo or
  rustup needed at boot time; the two lines are replaced with `sed` anchored
  to the bare call lines, so the function definitions stay intact).

Pinned revisions (in `flake.nix`, both source-only inputs, `flake = false`):

- `reims-vgpu` — `69a57dd69a6958e946c03b73e02db331f330f435` (master, 2026-09-03)
- `qemu-reims-vgpu` — `bd88218da09b86ed9c78bf5f9354168812a7ba6b`, the exact
  commit the superproject's `vendor/qemu` gitlink points at.

Bump both together and re-check `packages/reims-vgpu/reims-vgpu-efi.Cargo.lock`
if the UEFI crate's dependencies changed.

## Status on asusg16 (2026-09-21)

The host side is built, installed and verified; **the accelerated device does
not boot this guest on this host yet.**

What works:

- The nix-built QEMU fork boots the imported macOS 13.7.8 guest to a full
  desktop with `--device vmware-svga` (control test: Dock + WindowServer up).
- The device itself initialises: GOP ROM installs, host window opens, Vulkan
  device selection succeeds (NVIDIA RTX 5080 and Intel Arc both tried), the
  guest's first WindowServer frame is presented
  (`first guest frame presented via rail resident (same-device zero-copy)`).

### OpenCore auto-boot (fixed 2026-09-21)

The imported guest did not boot unattended: OpenCore's picker defaulted to its
own ESP entry ("EFI"), which just re-runs OpenCore, so every boot needed a
manual Right-Arrow + Enter. Cause: OSX-KVM's `config.plist` ships
`Misc/Security/ScanPolicy = 0`, i.e. scan every filesystem and device, so the
OpenCore disk's `\EFI\BOOT\BOOTX64.EFI` is scanned and becomes the first (and
therefore default) entry. OpenCore's documented macOS-only policy is
`0x10F0103` — the two locks plus APFS and SATA/SAS/SCSI/NVMe/PCI, with no ESP
— which removes the EFI entry and leaves macOS as the only entry, so the 2 s
timeout boots it.

Applied offline to the OpenCore image (partition 1 starts at sector 2048):

```sh
qemu-img convert -f qcow2 -O raw OpenCore.qcow2 OpenCore.raw
mcopy -i OpenCore.raw@@1048576 ::/EFI/OC/config.plist config.plist
python3 - <<'PY'
import plistlib
d = plistlib.load(open('config.plist','rb'))
d['Misc']['Security']['ScanPolicy'] = 0x10F0103
plistlib.dump(d, open('config.plist','wb'))
PY
mcopy -o -i OpenCore.raw@@1048576 config.plist ::/EFI/OC/config.plist
qemu-img convert -f raw -O qcow2 OpenCore.raw OpenCore-patched.qcow2
```

The result is the snapshot `base-autoboot` (now `current`); `base` is kept as
the unpatched history. Verified: a `--testing` boot reaches macOS with no
keypress. Any future re-import of an OSX-KVM OpenCore image needs this edit
again (or boot once, set Startup Disk, and `--capture` a new snapshot).

What fails, every time, with `--device reims-vgpu-pci`:

- The guest never reaches the desktop. It gets as far as the first
  WindowServer frame (Apple logo + progress bar ~30 %), then either the guest
  kernel wedges — 7 of 8 vCPUs spinning at the same kernel RIP
  (`ffffff80125bb1d2`), host ~600 % CPU, window frozen on the last frame
  (`host_window_loop … draws_fresh=0 draws_stale=10`) — or QEMU exits cleanly
  (guest reboot turned into an exit by `-action reboot=shutdown`).
- Tried and identical every time: `REIMS_VGPU_DMABUF=off`, Intel Arc ICD
  (`VK_ICD_FILENAMES=…/intel_icd.x86_64.json`), NVIDIA forced via
  `nvidia-offload`, tmux pty vs detached launch, 8 vCPUs (the script's cap).
- Upstream master has not moved since the pinned rev (`69a57dd`), and the open
  upstream issues in this family (e.g. #30, "Vulkan present loop stalls …
  NVIDIA/Linux") describe the same host class, so this looks like a device
  defect rather than local setup.

Evidence kept: `/tmp/opencode/reims-wedge-qmp.txt` (QMP register dump at the
wedge), `/tmp/opencode/reims-wedge-fail.log` (device fail log copy),
`/tmp/opencode/reims-*.log` (per-boot serial/host logs), plus
`/tmp/reims-vgpu-fail.log` (always-on device channel).

Until upstream fixes it, the usable boot on this host is the non-accelerated
console path:

```sh
reims-vgpu-boot --rail macos-13 --interactive --device vmware-svga
```

### Guest panic narrowed to the host-pointer import rail (2026-09-21)

With the device the guest reaches the **login window in ~20 s** (the compositor
renders through reims-vgpu: presents at 24-30 Hz), then the guest kernel panics
~4-6 s later in roughly 60 % of boots. A serial capture (`debug=0x8 -v` in
`boot-args`) shows a NULL page fault in the kernel — one capture was
`vnode_getiocount` ← APFS `getattrlistbulk` in a `com.apple.Mobile*` task — and
the earlier "wedges" were the panic rendezvous (other CPUs spinning). The
`vmware-svga` arm boots and stays at the login screen (3/3 controls).

Measured with a boot+60 s-soak harness (`/tmp/opencode/reims-debug/`):

- default (host-pointer imports on): ~60 % of boots die within seconds of the
  login window; 2/2 died in the final control window.
- `REIMS_VGPU_GUEST_IMPORT=off`: **5/5 survived**, across separate runs.
- Narrowing switches that did *not* help: `LAZY_WRITEBACK=off`,
  `STAMP_COALESCE=off`, `SHARED_TARGET=off`, `GPU_STAMP=off`,
  `PUSH_DESCRIPTORS=off`, `DYNAMIC_RENDERING=off`, `BUFFER_EXTENT=off`,
  `PRESENT_DEPTH=1`, `SWAPCHAIN_FIFO=on`, `UNUSED_BINDS=off`,
  `SAMPLED_IDENTITY=off`, `PAGE_GUARDS=off`, `BATCH_DRAWS=1`, 4 vCPUs.
- `REIMS_VGPU_WINDOW=0` is not usable: the guest never reaches WindowServer
  (the device's presentation is what the guest's display path waits on).
- The device reports no declines and the page-table coverage probe
  (`RANGE_COVERAGE=on`) shows no map-side divergence, so this is not the
  known guest page-table assertion class.

The packed-alias rails (`zc_packed_alias_import`, `zc_packed_ramblock`) only
run when host-pointer imports are on, so the corruption is either in the
RAMBlock import path or in those rails. Upstream's own note in
`packed_alias_import_align` describes a sibling failure of the same shape
("an 8 GiB-or-larger guest on a host whose importable heap is smaller … dies,
while the same guest with `REIMS_VGPU_GUEST_IMPORT=off` works").

**Fixed (2026-09-21) by upstream PRs, patched into the package:** [#81 "Fix
format texel accounting in direct guest writeback"](https://github.com/steelbrain/reims-vgpu/pull/81)
— this host's failing geometry was exactly that PR's repro
(`R32G32B32A32_UINT 1504x6016`, `144769024` active bytes; the planner treated
a 16-byte texel as 4 bytes and the copy overshot into unrelated guest memory)
— and [#79 "settle queued guest writes before the guest takes its pages
back"](https://github.com/steelbrain/reims-vgpu/pull/79) (stacked on #78).
With both applied and host-pointer imports **on**, **7/7 boot+soak runs
survived** (4×45 s + 3×90 s) where the unpatched build managed about 1/3. The
wrapper no longer forces the slow copying rail; `REIMS_VGPU_GUEST_IMPORT=off`
remains a fallback. The patches are in `packages/reims-vgpu/pr81.patch` and
`pr79.patch` and should be dropped once the PRs merge upstream.

Ruled out along the way: the import chunk size (a 1 GiB `IMPORT_SPAN_CEILING`
build behaved the same), the page-table coverage probe (no map-side
divergence), and every narrowing switch listed above.

Still open: an intermittent boot failure that predates the workaround — the
guest sometimes never reaches the login window (stuck before it, or an early
hang; the screen shows OpenCore's picker with the `macOS` volume and `REL:`
footer). The user saw this as the "stop sign → OpenCore → no autoboot" case.
It is unrelated to the import rail and needs its own investigation.

## How the package was made (things that bit)

Recorded so a future bump does not have to rediscover them:

- **Rust**: the host workspace (`crates/*`) vendors through
  `rustPlatform.importCargoLock`; the only git dependency is `metal2vulkan`,
  whose `outputHashes` entry is the fetchgit hash of its revision. The UEFI
  crate is a **separate workspace with no `Cargo.lock` upstream**; the lock
  next to `default.nix` was generated once (`cargo generate-lockfile`) and is
  copied into the tree before building.
- **rust-overlay** is required only for `x86_64-unknown-uefi` std, which
  nixpkgs' rustc does not ship.
- **QEMU subprojects**: `configure` hard-requires `subprojects/keycodemapdb`,
  and `tests/fp` (always configured, gated on TCG) pulls in
  `berkeley-softfloat-3` / `berkeley-testfloat-3`. The sandbox has no network,
  so all three are fetched with `fetchgit` and dropped into place, with
  QEMU's meson glue from `subprojects/packagefiles/` overlaid on the two
  float libraries (what a wrap's `patch_directory` would do). `--disable-download`
  makes a missing subproject a configure error instead of a network attempt.
- **Python**: QEMU's configure builds its own venv and installs its vendored
  meson wheel; `mkvenv` needs `distlib`/`packaging`, and the "tooling" group
  wants `setuptools`/`wheel`/`pip` visible so it does not reach for PyPI.
  Hence `python3.withPackages`.
- **RPATH**: QEMU's meson install drops the build-tree rpath, so
  `autoPatchelfHook` is needed to point the binary back at its store
  libraries.
- **Runtime dlopens**: the Rust staticlib loads `libvulkan.so.1` (ash), winit
  loads its windowing libraries, and `metal2vulkan` spawns `llvm-dis` and
  `spirv-val` per uncached shader. None of those are `DT_NEEDED`, so the QEMU
  wrapper prepends `LD_LIBRARY_PATH` (vulkan-loader, wayland, libxkbcommon)
  and `PATH` (llvm, spirv-tools).
- **Bash scripts lose their shebang interpreter in the sandbox**
  (`/usr/bin/env` does not exist); the UEFI ROM builder is invoked via `bash`.

## Provisioning the macOS guest (the manual part)

`macOS 13 Ventura` is the version the project recommends; the disk is
**512 GiB thin** (qcow2 only grows with what macOS actually writes).

1. **Fetch the installer media** (Ventura = menu entry 6):

   ```sh
   git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM ~/OSX-KVM
   cd ~/OSX-KVM
   ./fetch-macOS-v2.py          # choose 6 (Ventura); ~700 MB download + verify
   dmg2img -i BaseSystem.dmg BaseSystem.img
   qemu-img create -f qcow2 mac_hdd_ng.img 512G
   ```

2. **Install macOS** — interactive, needs the GUI window and keyboard:

   ```sh
   cd ~/OSX-KVM && ./OpenCore-Boot.sh
   ```

   In Disk Utility: erase/format the 512 GiB disk as APFS, then install.
   Expect several reboots and the Setup Assistant. Afterwards, inside the
   guest: enable **Remote Login** (System Settings → General → Sharing),
   disable sleep/screensaver, and optionally install an SSH key.

3. **Place the artifacts** where `reims-vgpu-boot` expects them:

   ```sh
   mkdir -p ~/reims-vgpu/vm/disks ~/reims-vgpu/vm/ovmf
   cp ~/OSX-KVM/mac_hdd_ng.img          ~/reims-vgpu/vm/disks/macos.img
   cp ~/OSX-KVM/OpenCore/OpenCore.qcow2 ~/reims-vgpu/vm/disks/OpenCore.qcow2
   cp ~/OSX-KVM/OVMF_CODE_4M.fd         ~/reims-vgpu/vm/ovmf/OVMF_CODE_4M.fd
   cp ~/OSX-KVM/OVMF_VARS-1920x1080.fd  ~/reims-vgpu/vm/ovmf/OVMF_VARS-1920x1080.fd
   ```

   `OVMF_VARS` is the NVRAM that the installer wrote to — copy the **post-
   install** file, not the pristine template. The `.img` name is a misnomer:
   the file stays qcow2 and the boot script passes `format=qcow2`.

4. **Freeze the first immutable snapshot** (boots writable; a clean guest
   shutdown captures it):

   ```sh
   mkdir -p ~/reims-vgpu/vm/disks/rails/macos-13
   reims-vgpu-boot --rail macos-13 --capture --device vmware-svga
   ```

   **What was actually done here** was the import path from the upstream
   README instead of a capture boot, because the guest was already installed:
   the post-install `mac_hdd_ng.img`, `OpenCore.qcow2`, `OVMF_VARS.fd` and
   `OVMF_CODE.fd` were copied with `cp --reflink=auto` (free on btrfs) into
   `vm/disks/rails/macos-13/snapshots/base/`, `chmod 444`, and
   `snapshots/current -> base`. No capture boot is needed when the guest was
   provisioned outside the harness.

## Day-to-day use

```sh
reims-vgpu-boot --rail macos-13 --interactive --device reims-vgpu-pci   # accelerated GUI
reims-vgpu-boot --rail macos-13 --testing     --device reims-vgpu-pci   # 7-min, auto-revert
```

### Persistence

The harness is **snapshot-revert by design**: `--testing` and `--interactive`
boot a throwaway COW clone and discard it on exit, and `--capture` only
promotes the clone to a new snapshot on a *clean* guest shutdown. A session
that crashes on the way out is lost.

For a normal persistent VM there is a locally patched boot class,
`--persistent`:

```sh
reims-vgpu-boot --rail macos-13 --persistent --device reims-vgpu-pci
```

It ignores rails and snapshots and boots the provisioned masters write-through:

| File | Path |
|---|---|
| Guest disk | `~/reims-vgpu/vm/disks/macos.img` |
| OpenCore | `~/reims-vgpu/vm/disks/OpenCore.qcow2` |
| OVMF vars | `~/reims-vgpu/vm/ovmf/OVMF_VARS-1920x1080.fd` |

Everything lands on those files as it happens — verified by writing a file in
the guest, `SIGKILL`ing QEMU, rebooting, and finding the file still there. The
masters were seeded from the `base-autoboot` snapshot with `cp --reflink=auto`
(free on btrfs). To reset the machine, re-copy them from a snapshot. The
revert classes remain available and are the right choice for experiments.

### The 2026-09-21 shutdown freeze

One long session ended in a "freeze": QEMU was actually **SIGABRT**ing in
`qemu_alloc_stack` — its `mmap` for a coroutine stack failed during the guest
shutdown's disk flush (`dma_blk_write` → `blk_aio_pwritev` →
`qemu_coroutine_create` → `qemu_alloc_stack` → `abort`). The process then hung
in the kernel's coredump path, because the core's ELF note exceeded
`kernel.core_file_note_size_limit` (the dump was 10.3 GB), which is what the
desktop saw as a freeze. Host had 52 GiB free, `vm.max_map_count` was already
1 MiB and there was no OOM, so the cause of the failed `mmap` is still open
(likely VMA exhaustion over a long session; a long watch of
`/proc/<qemu>/maps` is the instrument). `--persistent` means a crash like this
no longer costs the session's work.

- The display is a **Rust-owned winit + Vulkan window** ("Reims vGPU") opened
  by the device itself; QEMU is started with `-display none`. On KDE Wayland
  it grabs `Meta`/`Alt`/`Ctrl` chords for the guest — **`Ctrl+Alt+Esc`
  releases them**.
- Every boot clones the selected snapshot with `cp --reflink=auto` (btrfs on
  `/home`, so clones are metadata-only) and **throws the clone away on exit**.
  Only `--capture` plus a clean guest shutdown persists anything.
- `--testing` is the agent/measurement boot: 420 s hard kill, capture-then-
  revert, distinct exit codes (124 wedge, 125 firmware abort, 126 guest
  panic).
- SSH into the guest is forwarded to `localhost:2222` and is set up as host
  alias `macos-vm` in `~/.ssh/config` (user `tianyixia`, key
  `~/.ssh/id_ed25519`), which is the name the project's own probe scripts
  expect. In `--testing` boots the serial log is
  `~/reims-vgpu/vm/disks/run/serial-*.log`; in `--interactive` boots serial is
  muxed onto the launcher's stdout, so run it from a terminal/tmux if you want
  to see it. QMP sockets and trace logs land in the same `run/` directory, and
  the always-on device failure log is `/tmp/reims-vgpu-fail.log`.
- Because the interactive class muxes the monitor onto stdio, do **not**
  detach it with stdin on `/dev/null` — the stdio monitor hits EOF and QEMU
  exits cleanly. Use a real terminal or `tmux new-session -d …`.

## State layout

```
~/reims-vgpu/vm/
├── disks/
│   ├── macos.img                 # provisioned master (only used to bootstrap)
│   ├── OpenCore.qcow2
│   ├── rails/macos-13/snapshots/<label>/{macos.img,OpenCore.qcow2,OVMF_VARS.fd[,OVMF_CODE.fd]}
│   │   └── current -> <label>
│   ├── rails/current -> macos-13
│   └── run/                      # per-boot clones, serial-*.log, qmp-*.sock, trace-*.log
└── ovmf/
    ├── OVMF_CODE_4M.fd
    └── OVMF_VARS-1920x1080.fd    # vars template (post-install NVRAM)
```

Override the root with `REIMS_VGPU_VM_DIR=... reims-vgpu-boot ...`; every
`DISKS_DIR` / `OVMF_DIR` / `RAILS_DIR` / `RUN_DIR` / `QEMU_BIN` /
`REIMS_VGPU_GOP_ROM` variable from upstream still applies.

## What is deliberately still manual

1. The macOS install itself (interactive, Apple-licensed, tens of GB).
2. The first snapshot capture (a clean guest shutdown).
3. Guest-side configuration (Remote Login, no sleep).
4. Nothing here distributes macOS images, IPSWs or OpenCore/OVMF blobs.

## Troubleshooting

- `reims-vgpu-boot: no rail 'X'` — create the rail first:
  `mkdir -p ~/reims-vgpu/vm/disks/rails/X` (the bootstrap path requires an
  empty rail and `--capture`).
- Host window shows nothing / no Vulkan: check that the NVIDIA ICD is visible
  (`/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json`) and that
  `XDG_DATA_DIRS` reaches `/run/opengl-driver/share`; the loader discovers
  ICDs there.
- Shader translation errors mention `llvm-dis`/`spirv-val`: the wrapper puts
  both on `PATH`; running upstream's `vm/boot-x86.sh` by hand needs
  `llvm` and `spirv-tools` on `PATH` (they are in `environment.systemPackages`
  for that reason).
- Disk only grows: there is no `discard=unmap` on the drives, so guest-side
  deletes do not shrink the qcow2. Shut down and run
  `qemu-img convert -O qcow2 macos.img macos-shrunk.img` to reclaim.
