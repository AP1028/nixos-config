# Steam on aarch64 (Asahi) — the Fedora Asahi Remix stack on NixOS

`programs.steam-asahi` (enabled on the macbook) installs a NixOS port of
Fedora Asahi Remix's `dnf install steam`. The pieces are the same ones Fedora
ships:

| Fedora | here |
| --- | --- |
| `steam` (COPR `@asahi/steam`) | `packages/steam-asahi.nix` |
| Valve `steam_1.0.0.87.tar.gz` bootstrap launcher | fetched, same tarball |
| `fex-emu` | nixpkgs `fex` (stock) |
| `muvm` | nixpkgs `muvm` (stock) |
| `fex-emu-rootfs-fedora` | FEX's official `Fedora_44.ero` image |
| `mesa-fex-emu-overlay` | the FEX GL/Vulkan/ALSA thunks built by nixpkgs `fex` |
| `virglrenderer > 1.2` | nixpkgs `virglrenderer` 1.3 |
| the `steam` shim (`shim.py`) | `bin/steam` launcher script |

Flow: `steam` → `muvm -x <guest setup> -- <runtime launcher>` → the runtime
launcher (native aarch64, inside the 4K-page microVM) starts a session D-Bus
and runs FEX → FEX runs Valve's x86_64 `bin_steam.sh` → the client
self-updates into `~/.local/share/Steam` and games run through Proton under
FEX, exactly as on Fedora.

## NixOS adaptations (and why)

* **The Fedora rootfs is unpacked into the store and bind-mounted**, instead
  of configuring FEX's `RootFS`. On NixOS, pressure-vessel's bwrap trips over
  `--ro-bind /etc/host.conf` with FEX RootFS redirection enabled (`bwrap:
  Can't get type of source /etc/host.conf`). With no FEX RootFS at all, every
  path is real and that failure disappears. The guest setup binds the rootfs
  over `/usr`, `/bin`, `/lib`, `/lib64` and over an `/etc` that has the host's
  `passwd`/`group`/`shadow`/`machine-id`/`hosts` stitched in (the rootfs has
  no user database; muvm needs the host's to resolve the user and `$HOME`).
* **Stock `fex`/`muvm`**: the macbook's overlays patch FEX for the Cadence
  work (16K jemalloc, extra diagnostics). FEX runs in the *4K-page* guest,
  where a 16K jemalloc build is wrong (observed SIGSEGV). The module
  instantiates a stock nixpkgs for this package.
* **`/sbin -> usr/sbin`** is created by activation: Steam's runtime scripts
  call `/sbin/ldconfig`, and NixOS has no `/sbin`. Inside the guest `/usr` is
  the Fedora rootfs, so the symlink resolves there.
* **Guest inotify limits** are raised (`max_user_instances=8192`) because CEF
  exhausts the libkrun guest's default of 128.
* A **system + session D-Bus** runs in the guest (Fedora has both on the host;
  the Steam runtime and CEF expect them).
* **Fonts**: the Fedora rootfs only ships Latin fonts, so the guest setup
  copies `/etc/fonts/conf.d/00-nixos-cache.conf` from the host into the
  guest's Fedora fontconfig. That conf lists the host's font store paths
  (Noto CJK, Sarasa, HarmonyOS, ...) and NixOS's prebuilt font cache; since
  the Nix store is shared with the guest, this makes all host fonts available
  to Steam without copying any font files.

## Status (2026-09)

Working: `bin_steam.sh` bootstrap, client self-update, sign-in state, the
client UI (CEF `steamwebhelper` renders the Store/library; verified visually
via a screenshot of the running system `steam`). Launching games has not been
exercised yet.

Notes:

* `~/.local/share/Steam` is the normal writable client directory. If it still
  contains `package/beta = publicbeta` from the old arm64 experiments, the
  x86 client opts into the Valve publicbeta; remove that file for stable.
* The VM is isolated in `$XDG_RUNTIME_DIR/steam-muvm` so it cannot collide
  with `cadence-env`'s VM.
* Old runtime VMs are named `libkrun VM` (comm), so `pkill -x muvm` does not
  kill them; use `pkill -x "libkrun VM"` when debugging.
