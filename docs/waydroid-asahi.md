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
| `waydroid-data-image.service` + `systemd.mounts` | Android's vold/MediaProvider stamp project-quota IDs on `/data/media`; btrfs (this host's `/home`) refuses, so the emulated storage volume never comes up. The session data dir therefore lives on a 32 GiB sparse **ext4 loop image** (`/var/lib/waydroid/data.img`, `-O quota,project`, mounted `loop,prjquota`) created once and migrated by the oneshot; the mount unit starts before `waydroid-container.service`, which requires it. |
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

# 4. launch the UI — prefer the "Waydroid" app-menu entry.  Android idles by
#    freezing the container (`suspend_action=freeze`), which is normal: showing
#    the UI again unfreezes it.
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

## Known limitations

* **Camera** does not work (removed from the image build).
* **Bluetooth** is non-functional (errors merely suppressed at build time).
* **No hardware video decode** — only software codecs are enabled.
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
