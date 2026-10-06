# Bottles on aarch64 (Asahi) — Bottles inside muvm

`modules/packages/bottles-cpak.nix` (enabled on the macbook) installs:

* `services.cpak` — the [cpak](https://cpak.it) runtime (from
  `github:Containerpak/cpak/v2`), and
* `packages/bottles-asahi.nix` — the `bottles-asahi` /
  `bottles-asahi-install` wrappers, which run Bottles **inside muvm's 4K-page
  microVM** plus a desktop entry.

```bash
bottles-asahi-install     # first run: fetch Bottles into the guest store
bottles-asahi             # launch it (inside the microVM)
bottles-asahi --install   # later: update Bottles
```

## Why this shape

### 1. Bottles on aarch64 exists only as a cpak package

| path | works on the macbook? |
| --- | --- |
| Flathub `com.usebottles.bottles` | **No** — published for x86_64 only (`app/com.usebottles.bottles/x86_64/stable`, SDK `org.gnome.Sdk/x86_64/50`). The asusg16's `modules/packages/flatpak-bottles.nix` cannot be reused. |
| nixpkgs `bottles` / `bottles-unwrapped` | **No** — fails to *evaluate* on `aarch64-linux`: it is a `buildFHSEnv` with `multiArch = true` (for 32-bit Wine), which needs `pkgsi686Linux`; the i686 package set only exists on x86. Verified: `error: i686 Linux package set can only be used with the x86 family`. |
| cpak ARM64 release | **Yes** — the only ARM64 packaging; Bottles 67.4 with the Soda ARM64/ARM64EC runner. |

Upstream's stated reason for shipping the ARM64 test release as cpak: *"it is
the first packaging path where the application, Wine base and native ARM CI
are available together."*

### 2. It has to run under muvm

This host runs a **16 KiB page size** kernel (`getconf PAGESIZE` → 16384).
Bottles runs x86/x86_64 Windows binaries through FEX, and FEX only works with
4 KiB pages — hence muvm's microVM with a separate 4K guest kernel, exactly as
`programs.steam-asahi` does for Steam
([Fedora Asahi x86 support](https://docs.fedoraproject.org/en-US/fedora-asahi-remix/x86-support/)).
This repo already states it in `hosts/macbook/system/default.nix`: *"FEX only
runs on 4K-page kernels, so it is used inside the muvm microVM."*

### 3. cpak needs a real filesystem inside the guest

Launching cpak directly in the guest does not work. When an application
starts, cpak composes its root with a **rootless OverlayFS** mount, and
overlayfs refuses the guest's root filesystem as an upperdir:

```
$ muvm -- cpak doctor
[OK]   unprivileged user namespaces: ... can be created
[FAIL] rootless OverlayFS: mount: .../merged: cannot mount overlay read-only.
```

The guest root is `virtiofs` (libkrun's FUSE-derived passthrough). Overlayfs
rejects FUSE-style filesystems (they set `d_revalidate`) for upper/work
directories. cpak has a `fuse-overlayfs` fallback, but `cmd/spawn.go` only
takes it on `EPERM`/`EACCES`, and `/dev/fuse` in the guest is `0600 root`, so
that path is not usable either.

The fix: give cpak a filesystem overlayfs accepts — a **loop-mounted ext4
image**. `packages/bottles-asahi.nix`:

1. The wrapper creates a sparse image at
   `~/.local/share/bottles-asahi/store.img` (64 GiB, grown on demand) in the
   **real** `$HOME`, so installed applications survive VM restarts.
2. muvm's `-x` pre-command (guest root) attaches it
   (`losetup` → `mkfs.ext4` on first run → `mount`) at
   `/run/bottles-asahi/store` and hands the mount to the invoking user.
   The libkrunfw guest kernel is built with `CONFIG_BLK_DEV_LOOP=y` and
   `CONFIG_EXT4_FS=y`, `/dev` is devtmpfs and `/dev/loop-control` exists.
3. `CPAK_INSTALLATION_PATH=/run/bottles-asahi/store/cpak` puts cpak's whole
   installation (store, layers, composed roots, cache, exports) on ext4.

With that, the same check inside the guest reports:

```
[OK] rootless OverlayFS: overlay mount with userxattr succeeded in a user namespace
```

Only `[FAIL] Landlock: function not implemented` remains — the libkrunfw guest
kernel has no LSM at all. cpak documents Landlock as an optional hardening
layer, and Bottles' own manifest says *"Nested sandboxes: ... disables
Landlock"*, so it does not affect running Bottles.

## Where things live

| what | where |
| --- | --- |
| Bottles + Wine runners + FEX | ext4 image `~/.local/share/bottles-asahi/store.img`, mounted at `/run/bottles-asahi/store` inside the guest |
| Bottled Windows prefixes | real `$HOME/.local/share/bottles` (the manifest maps it explicitly) |
| Bottles icons | real `$HOME/.local/share/icons` (same) |
| per-run microVM state | guest-private `/run`, discarded |

The 64 GiB figure is the *maximum* size: `store.img` is sparse and only the
data actually written (a few GiB for Bottles plus its Wine runner) occupies
disk.

## Runtime details

* muvm exposes **X11 only** (the host's XWayland). The runtime pins
  `GDK_BACKEND=x11` and clears `WAYLAND_DISPLAY`.
* A **session D-Bus** is started inside the guest and exported as
  `DBUS_SESSION_BUS_ADDRESS`. This is required: cpak starts a
  `desktop-bus-proxy` for the sandbox whose upstream is that variable (falling
  back to `/run/user/<uid>/bus`, which does not exist in the guest's private
  `/run`), and it waits 3 s for the proxy socket before failing with
  `start desktop bus proxy: no cpak service answered ...`.
* The wrapper takes an exclusive `flock` on
  `~/.local/share/bottles-asahi/.lock` for the guest's lifetime. muvm only
  handles one guest at a time on this host, and two guests must never attach
  the same ext4 image.
* `XDG_RUNTIME_DIR` is repointed at `$XDG_RUNTIME_DIR/bottles-asahi-muvm` so
  this microVM cannot collide with `steam-asahi`'s or `cadence-env`'s.

## Caveats

* **File pickers and host integration are degraded.** cpak's file-chooser
  broker (`system-broker`) and the desktop-dialog adapters are host services;
  the guest has no system authority and no system D-Bus, so opening/saving
  files from inside a bottle may not show the host dialog. Everything else
  (bottles, runners, FEX, launching apps) is self-contained.
* **Verified launch is not available.** `cpak install` warns: *"not enrolled
  for verified launch: no system authority is reachable."* Enrollment is an
  optional policy feature (host enforcement is `off` by default).
* **Performance.** This is FEX emulation inside a microVM; expect the same
  rough performance class as Steam's Proton-on-Asahi, plus Wine overhead.
* **First launch is slow** — Bottles downloads its Soda runner and FEX from
  its component catalog into the image.

## Status (2026-10)

Verified end-to-end on the macbook, with the installed wrappers:

* `bottles-asahi-install` → `INSTALL_EXIT=0`; `cpak list` shows
  `Bottles | main | github.com/bottlesdevs/bottles`.
* `bottles-asahi` → Bottles launches inside muvm. `cpak logs` shows
  `Container prepared: ...` and `Executing command:/usr/bin/bottles`, and the
  process was still alive when the test's 75 s timeout killed it
  (`RUN_EXIT=124`, i.e. it did not exit or crash).
* `cpak doctor` inside muvm on the ext4 store: user namespaces, rootless
  OverlayFS, `mount_setattr`, seccomp, X11 display and PipeWire all `[OK]`
  (Landlock `[FAIL]`, optional — see above).
* The full macbook system closure builds with the wrapper in
  `environment.systemPackages` (`bottles-asahi`, `bottles-asahi-install`,
  `bottles-asahi.desktop`).

Two failure modes found while getting there, kept here because they are the
easy ways to reintroduce a bug:

* Without a guest session D-Bus, `cpak run` dies with `start desktop bus
  proxy: no cpak service answered on .../desktop-bus.sock within 3s` — hence
  the `dbus-daemon --session` in the runtime script.
* `pkgs.callPackage` silently fills the package's `cpak` argument with
  **nixpkgs' `cpak` (2.13.3)**, not the flake module's 2.14.2. The store is
  version-coupled, so the module passes `config.services.cpak.package`
  explicitly.

Not exercised yet: creating a bottle and running an x86/x86_64 Windows
application through the Soda runner (that downloads the runner into the image
and is the real FEX test).

After the first switch, `~/.local/share/bottles-asahi/store.img` holds the
guest store (~2.5 GiB for Bottles plus its Wine base; `--install` reports
"already installed" and can be re-run to update).
