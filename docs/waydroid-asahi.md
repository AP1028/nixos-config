# Waydroid on aarch64 (Asahi) — Android 16 on a 16 KiB-page kernel

`hosts/macbook/waydroid.nix` enables Waydroid (Android in an LXC container) on
the macbook and pins Android images that actually run on Apple Silicon.

## Why stock Waydroid cannot work here

* Asahi kernels use **16 KiB pages** — the IOMMUs and GPU only work with them,
  so building a 4 KiB kernel is not an option (marcan, [waydroid#577]).
* Waydroid does not boot its own kernel: the Android userspace runs directly on
  the host kernel inside an LXC container. The *images* must therefore be
  16 KiB builds. Waydroid's own OTA channel still tops out at LineageOS 20
  (Android 13) built for 4 KiB, and the bionic linker/page-size assumptions in
  such images abort on a 16 KiB kernel.
* Android 15+ does support 16 KiB pages, but only in images configured with
  `PRODUCT_MAX_PAGE_SIZE_SUPPORTED := 16384`. No official Waydroid image is.
* `muvm` (the 4 KiB microVM used for Steam/FEX) is not a way out either:
  Waydroid needs a full LXC-capable system *and* the Mesa build that only the
  Android image carries.

[waydroid#577]: https://github.com/waydroid/waydroid/issues/577

## What the module does

| piece | why |
| --- | --- |
| `virtualisation.waydroid.enable` | the nixpkgs module: Waydroid 1.6.3, LXC, gbinder, `waydroid-container.service`, `waydroid0` in the firewall's trusted interfaces, `psi=1`, and the `ANDROID_BINDER_IPC` / `ANDROID_BINDERFS` / `MEMFD_CREATE` kernel-config assertions. |
| `environment.etc."waydroid-extra/images/{system,vendor}.img"` | `/etc/waydroid-extra/images` is one of Waydroid's `preinstalled_images_paths`. When both images are present Waydroid skips `images.get()` entirely (it never contacts `ota.waydro.id`) and sets `waydroid.updater.disabled=true`, so the 16 KiB images can never be overwritten by upstream 4 KiB ones. |
| `virtualisation.waydroid.package = pkgs.waydroid-nftables` | the Asahi kernel sets `CONFIG_NETFILTER_XTABLES_LEGACY=n`: it ships `nf_tables` (plus `nft_nat`, `nft_masq`, `nft_chain_nat`) but **no legacy `ip_tables` modules**, so the default build's `waydroid-net.sh start` dies with `iptables ... can't initialize iptables table 'filter': Table does not exist` and the container never boots. The nftables build flips the script's `LXC_USE_NFT` to true. nixpkgs only picks it automatically when `networking.nftables` is enabled, which would move the whole host firewall, so it is selected explicitly. |
| `~/.config/autostart/waydroid-session.desktop` | the `Waydroid` desktop entry runs plain `waydroid`, which only *shows* an already running session — it never starts one. The session manager is therefore autostarted with the graphical session. |
| `waydroid-data-image.service` + `systemd.mounts` | Android's vold/MediaProvider stamp project-quota IDs on `/data/media`; btrfs (this host's `/home`) refuses, so the emulated storage volume never comes up. The session data dir therefore lives on a sparse **ext4 loop image** (`/var/lib/waydroid/data.img`, `-O quota,project`, mounted `loop,prjquota`) created once and migrated by the oneshot — 128 GiB apparent by default (`dataImageSize`), since Android's `/data` *and* `/sdcard` share it and only written blocks cost host disk. The service re-enforces that size on every boot (`truncate` + `e2fsck -f -p` + `resize2fs`, grow-only), and `waydroid-sdcard-access.service` adds an ACL so the host user can copy files straight into `/sdcard`; the mount unit starts before `waydroid-container.service`, which requires it. |
| `waydroid-storage.service` | vold does not mount the emulated storage volume on its own under Waydroid (see below), so this keeps `/sdcard` mounted while the container runs. |

The Asahi kernel already has binder, binderfs and memfd built in, so no kernel
modules are needed: Waydroid mounts binderfs itself at `/dev/binderfs` and only
then creates `/dev/binder`, `/dev/hwbinder` and `/dev/vndbinder`. AppArmor is
disabled on this host, so Waydroid's LXC profile runs unconfined.

## Android storage

`/data` is an ext4 loop image (see the table above). btrfs is not enough on its
own: even on ext4, `dumpsys mount` reports `VolumeInfo{emulated;0}
state=UNMOUNTED path=null` after boot and `/sdcard` does not exist until
something calls `sm mount`. That is why an earlier attempt looked dead — `sm` is
a Java command that needs Android's full environment (`BOOTCLASSPATH`,
`ANDROID_*`), which only `waydroid shell` provides; through a plain
`lxc-attach` it exits silently and does nothing. `waydroid-storage.service`
polls a **RUNNING** container (never a frozen/idle one, which would defeat
`suspend_action=freeze`), runs `sm mount <emulated;N>` plus a MediaProvider
`scan_volume`, and leaves it alone once `sm list-volumes all` reports it
mounted. Verified by stop/start A/B: without the service `emulated;0 unmounted`,
with it `mounted` and a write to `/sdcard` succeeds as an app uid.

## Vulkan

**Hardware Vulkan does not work on these images, and nothing host-side can
change that.** The image sets `ro.hardware.vulkan=asahi` but ships Mesa's Asahi
Vulkan driver as `/vendor/lib64/hw/vulkan.pastel.so`. Making the property's
target exist (aliasing `vulkan.asahi.so` in the vendor overlay — it resolves and
reads fine in the container) is not sufficient: `cmd gpu vkjson` still reports
the fallback `SwiftShader Device (LLVM 16.0.0)`. The shipped library is a plain
Mesa ICD (it exports `vk_icdGetInstanceProcAddr`) rather than the Android HAL
module the loader expects, and `ro.hardware.vulkan` cannot be overridden from
`waydroid.prop` because the image sets it first and `ro.*` is write-once.

What you do get: GLES is hardware accelerated — SurfaceFlinger reports `GLES:
Mesa, Apple M2 (G14G B0), OpenGL ES 3.2 Mesa 26.0.6` — and apps that insist on
Vulkan fall back to SwiftShader (software). Hardware Vulkan needs an image built
with Android's `VK_ANDROID_native_buffer` support, e.g. the HLM319 LineageOS
23.2 tree; that is an Android build, not a configuration change.

## DMA-BUF heaps (the "Missing DMA-BUF support" warning)

Waydroid's host-side init logs this on every container start:

```
waydroid-init: DMA-BUF system heap does not exist, video playback might not work properly
```

and Android agrees in logcat:

```
E DMABUFHEAPS: No ion heap of name system exists
```

Both are correct, and the cause is the kernel, not Waydroid:

```
$ ls /dev/dma_heap                     # no such directory: no heap devices at all
$ zcat /proc/config.gz | grep DMABUF
# CONFIG_DMABUF_HEAPS is not set
```

The Asahi kernel is built without the DMA-BUF heaps framework, so
`/dev/dma_heap/system` does not exist on the host; Waydroid's LXC config binds
the `/dev/dma_heap/*` glob and therefore binds nothing, and Android's
`libdmabufheap` finds no heap. It does **not** affect what works: the container
allocates graphics buffers through `ro.hardware.gralloc=minigbm_gbm_mesa` on
`/dev/dri/renderD128`, so GLES/HWUI, apps and storage are fine. Only DMA-BUF /
zero-copy paths (video) are affected — and these images have no hardware video
codecs anyway, so playback is software-decoded regardless.

**Fixed (2026-10).** `hosts/macbook/hardware/default.nix` now builds
`linux-asahi` with the patch below, so the host has `/dev/dma_heap/system`
(`0666 root root`) and the `waydroid-init` / `DMABUFHEAPS` messages are gone.
Two things to know if you redo this:

* It needs a full `linux-asahi` build (~30–60 min here) and a reboot.
* **Re-run `waydroid init -f` afterwards.** Waydroid writes the LXC device
  entries in `set_lxc_config()`, which only runs at init time — a container
  started from an older config keeps a `config_nodes` with no `dma_heap` line,
  so the container still has no `/dev/dma_heap` and Android keeps logging the
  warning even though the kernel now provides the heap. After re-initialising,
  `config_nodes` contains
  `lxc.mount.entry = /dev/dma_heap/system dev/dma_heap/system none bind,create=file,optional 0 0`
  and the node appears in the container as `/dev/dma_heap/system`
  (`0444 system system`, which is the image's own `/system/etc/ueventd.rc`
  rule and normal for the heap API).

```nix
boot.kernelPatches = [
  {
    name = "dmabuf-heaps";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      DMABUF_HEAPS = yes;
      DMABUF_HEAPS_SYSTEM = yes; # provides /dev/dma_heap/system
    };
  }
];
```

It still does not give hardware video decode on this image (no hardware
codecs), and the graphics path in use remains
`ro.hardware.gralloc=minigbm_gbm_mesa` on `/dev/dri/renderD128`.

## Images

| file | source | size | sha256 |
| --- | --- | --- | --- |
| `system.img` | [waydroid-on-asahi lineage-23.0](https://github.com/UtkarshVerma/waydroid-on-asahi/releases/tag/lineage-23.0) | 1 926 283 264 B | `d15531bc174ca4eba7daad96cc8088b923326c45380b61f5356a5939c6ad5252` |
| `vendor.img` | same release | 230 678 528 B | `7bc46421d640a26f973cc77f5e660225c82e1ece401e2966428ae0beb90dec45` |

They are LineageOS 23.0 (Android 16, SDK 36) builds with the 16 KiB page-size
flags and Mesa's asahi (gallium) plus pastel (Vulkan) drivers, so the container
renders through the host's AGX GPU on `/dev/dri/renderD128`. Verified on import
without root:

```sh
# e2fsprogs' debugfs reads the ext4 images read-only, no root or loop mount
# needed (dump a file, then inspect it; /init is a symlink, use a real file).
debugfs -R "cat /build.prop" /etc/waydroid-extra/images/vendor.img \
  | grep ro.vendor.build.version        # -> release=16, sdk=36
debugfs -R "dump /bin/sh /tmp/waydroid-sh" /etc/waydroid-extra/images/system.img
# every PT_LOAD segment of /tmp/waydroid-sh has p_align = 0x4000 (16 KiB)
```

nixpkgs ships Waydroid **1.6.3**, the first release with Android 16 image
support, together with libgbinder 1.1.45 and gbinder-python 1.3.1.

## First run

```sh
# 1. switch (the images are already realized in the store by this change)
./rebuild.sh macbook
#    or: sudo nixos-rebuild switch --flake /etc/nixos#macbook
#    The only new kernel parameter is psi=1, which is a no-op (CONFIG_PSI is
#    already on), so no reboot is needed before first use.

# 2. initialize from the preinstalled images (needs root)
sudo /run/current-system/sw/bin/waydroid init -f
#    absolute path because sudo resets PATH; with this repo's helper:
#    sudo-env -c 'waydroid init -f'
#    Re-running init is safe: the ext4 /data image is not touched and
#    /sdcard is re-mounted by waydroid-storage.service.

# 3. start the session from your Wayland (Plasma) session.  It is autostarted
#    at login; to start it by hand now:
waydroid session start

# 4. launch the UI.  Two app-menu entries exist: "Waydroid" (the package's,
#    which runs bare `waydroid` = first-launch) and "Waydroid (Full UI)" (from
#    hosts/macbook/waydroid.nix, which runs `waydroid show-full-ui` directly).
#    Android idles by freezing the container (`suspend_action=freeze`), which is
#    normal: showing the UI again unfreezes it.
waydroid show-full-ui

# 5. apps (arm64-only images: no libhoudini/libndk bridge, so no 32-bit APKs)
waydroid app install foo.apk
waydroid app launch org.example.foo
waydroid shell
```

## Status (2026-10)

Working on the macbook: the container boots to Android 16, `sys.boot_completed=1`,
SurfaceFlinger/system_server/zygote run, the UI renders through Mesa/minigbm
(`ro.hardware.gralloc=minigbm_gbm_mesa`, `ro.hardware.egl=mesa`, GLES on the AGX
GPU), the container gets `192.168.240.112` on `waydroid0`, `/sdcard` is mounted
and writable, and `waydroid app install` / `waydroid shell` work.

## 16 KiB-page app compatibility (the RELRO end)

Apps linked for 4 KiB pages can crash here even when their alignment looks
perfect. Kirikiroid2 (`org.github.krkr2` 1.4.4) did: it launched, drew a frame
and died ~200 ms later with

```
signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), thread "GLThread 41"
  #00 libSDL2.so (SDL_DYNAPI_entry+280)
  #03 libgame.so  TVPAppDelegate::applicationDidFinishLaunching()+36
  #04 libgame.so  cocos2d::Application::run()+16
```

The faulting instruction is `stp x13, x14, [x8]` with `x8` = library base +
`0x122070`. bionic mprotects `PT_GNU_RELRO` read-only after relocation and
rounds the region's end **up** to the page size:

```
libSDL2.so: PT_GNU_RELRO vaddr=0x11e238 memsz=0x3dc8 -> end 0x122000
            .data starts at 0x122000; SDL's dynapi jump table is at .data+0x70
  4 KiB pages  : round_up(0x122000) = 0x122000  -> .data writable        ✓ works
  16 KiB pages : round_up(0x122000) = 0x124000  -> first 8 KiB of .data is
                 read-only, and SDL_DYNAPI_entry's memcpy() of its jump table
                 there is the first write -> SIGSEGV / SEGV_ACCERR
```

So there are **three** 16 KiB requirements and only the first two are widely
checked: segment `p_align >= 16 KiB`, uncompressed `.so` entries 16 KiB-aligned
in the APK, and **the end of `PT_GNU_RELRO` 16 KiB-aligned**. This app's
`libSDL2.so` is a prebuilt 2019-era 1.3.9 library (the project reuses old `.so`
files in its releases because the source lacks the plugins), hence 4 KiB
linkage; its arm64 `libffmpeg.so`/`libkrkr2.so` happen to be aligned already.

Fix it by shadowing the library, **not** by patching the APK. Android verifies
APK signatures again when PackageManager re-scans at boot, so an APK modified
after the fact is not merely ignored: the package is dropped and its directory
deleted ("`BackupManagerService: Package org.github.krkr2 not installed`", and
`/data/app/.../org.github.krkr2*` disappears — this is what happened here).
Leave the APK alone and write the fixed library into the app's **own lib dir**:
the app's linker namespace searches that directory before the APK
(`library_path=/data/app/<pkg>/lib/arm64:…/base.apk!/lib/arm64-v8a`, as
`nativeloader` logs), so the fixed copy is the one that gets mapped.

```sh
# the APK and its lib dir live inside Waydroid's /data, which the host mounts
# at ~/.local/share/waydroid/data
APK=$(ls ~/.local/share/waydroid/data/app/*/org.github.krkr2*/base.apk)
LIBDIR=$(dirname "$APK")/lib/arm64
scripts/patch-waydroid-16k-relro.py "$APK"                  # report (exit 1 if a fix is needed)
sudo scripts/patch-waydroid-16k-relro.py --emit "$LIBDIR" "$APK"
sudo chown 1000:1000 "$LIBDIR"/*.so && sudo chmod 644 "$LIBDIR"/*.so
```

`--emit` rewrites `PT_GNU_RELRO.p_memsz` (so the region ends on the previous
16 KiB boundary; RELRO still covers all but its tail) and removes stale copies
of libraries that no longer need fixing, so re-running it is safe. Ownership
`1000:1000` is Android's `system`.

This is declarative here: `waydroid-krkr2-16k-libs.service` runs the same
`--emit` on every boot against whatever APK is installed, so app updates and
reinstalls are covered. Verified by inspecting the running process:

```
$ grep libSDL2 /proc/$(pidof org.github.krkr2)/maps
… r-xp … /data/app/~~Dj0gr…/org.github.krkr2-…/lib/arm64/libSDL2.so
```

with the package still installed after an Android reboot and no new tombstone.

Caveats and notes:

* `--emit` only helps libraries the loader finds through the lib dir; if some
  future build stops listing it first, fall back to reporting upstream.
* The `armeabi-v7a` copies in the APK are misaligned too, but these images are
  arm64-only, so only the `arm64-v8a` libraries can ever be loaded.
* The durable fix is relinking the library with `-Wl,-z,max-page-size=16384`;
  the app is open source (`2468785842/krkr2`), so this is worth reporting
  upstream.
* Patching an APK *copy* (`--apply`) is still useful for extracting a fixed
  library, but never deploy that copy as the installed APK.

Any other old app can be checked the same way — run the script in report mode
on its APK.

## Kirikiroid2: why games would not open (two Android-side causes)

The APK itself is fine, and the earlier `libSDL2.so` fix only got the UI up.
Starting a game crashed with an uncaught `TJS::eTJSError` (SIGABRT on the GL
thread, from `TVPMainFileSelectorForm::onCellClicked`).  Reading the live
exception off the running process with gdb (the container's processes are
ordinary host processes, so `gdb -p` works; see below for the recipe) gave:

    Cannot open storage file://./storage/emulated/0/krkr2/[kr] 9 nine 1.<...>/data.xp3

Note `[kr]` -- lowercase -- while the directory on disk is `[KR]`.  The engine
lowercases the paths it opens (Windows-era case-insensitivity) and Android
storage is case-sensitive, so the open fails and the exception escapes the
JNI boundary.  Fix: keep every path in the library lowercase:

```sh
scripts/fix-krkr2-lowercase.py ~/.local/share/waydroid/data/media/0/krkr2       # dry run
sudo scripts/fix-krkr2-lowercase.py --apply --recursive <same>
```

With that, the engine reads `data.xp3`/`video.xp3` and loads `startup.tjs`,
`KAGLayer.tjs`, `Plugin.tjs`, `envinit.tjs`, `standview.tjs`, `UILoader.tjs`,
`AfterInit.tjs` -- i.e. the game starts.

Second cause: `MediaProvider`'s FUSE daemon (uid `media_rw`) refused the writes
the engine makes at startup (`saveSystemVariables失敗 : rename failed: ...`).
Host-copied files are owned by the host user, which the FUSE daemon cannot
write through.  Make the library look like Android created it:

```sh
sudo chown -R 10139:1023  ~/.local/share/waydroid/data/media/0/krkr2   # app uid : media_rw
sudo chmod -R g+rwX       ~/.local/share/waydroid/data/media/0/krkr2
sudo find  ... -type d -exec chmod g+s {} +                            # new files inherit media_rw
```

(10139 is `org.github.krkr2`'s uid; `dumpsys package org.github.krkr2` or a
tombstone shows it.  Replacing the FUSE mount with a plain bind mount of
`/data/media` also gives the engine full rw, but the app's own file-list UI
goes empty, so keep FUSE and fix ownership instead.)

To read an engine exception message:

```sh
# find the app's host pid and the throw site from the tombstone, then
sudo gdb -p <pid> -batch -x cmds      # break at the throwing function's
                                      # `bl __cxa_throw` (address = lib base +
                                      # offset from the tombstone), pass
                                      # SIGSEGV/SIGBUS, and read the exception
                                      # object via /proc/<pid>/mem while gdb
                                      # holds the process stopped
```

How to launch a game: the app is a two-pane launcher -- the left pane shows the
selected game with a **play button**, the right pane is the file browser.  Tap
`krkr2`, tap the game folder, then press **play**.  (Tapping `data.xp3` in the
right pane also works now, but play is the intended path.)

Status: **working** -- with the library lowercased and properly owned, the
engine loads `data.xp3`/`video.xp3`, runs the game's `startup.tjs`/KAG scripts
and reaches the title screen with BGM and voice (verified with the KR-patched
*9-nine- Episode 1*, no tombstones).

When more games are copied in from the host, run

```sh
sudo scripts/prepare-waydroid-games.sh ~/.local/share/waydroid/data/media/0/krkr2
```

which lowercases the names, applies the app:media_rw ownership and re-adds the
host user's ACL.

## Known limitations

* **Camera** does not work (removed from the image build).
* **Bluetooth** is non-functional (errors merely suppressed at build time).
* **No hardware video decode** — only software codecs are enabled. The
  DMA-BUF system heap itself is now provided (kernel rebuild + re-init; see
  the DMA-BUF section), but that does not add hardware codecs.
* **No hardware Vulkan** — see the Vulkan section above; apps fall back to
  SwiftShader. GLES is hardware accelerated.
* **No GApps** in these images (VANILLA build).
* **arm64-only** images: no 32-bit APKs, and no libhoudini/libndk translation.
* `waydroid init` needs root and the `waydroid-container` service must be
  running; the GUI initializer goes through polkit instead.

## Bumping the images

Edit both `url`s and `hash`es in `hosts/macbook/waydroid.nix`, then rebuild.
The `hash` is the asset's sha256 from the release API. Note that GitHub has
repeatedly flipped that release back to draft, making the asset URLs 404 for a
while — if the fetch fails, the asset is temporarily unpublished, not corrupt.
A newer HLM319 build (LineageOS 23.2, plus a `VK_ANDROID_native_buffer` patch)
exists as an alternative source, but it is a from-source patch set rather than
a published image release.
