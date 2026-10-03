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

The Asahi kernel already has binder, binderfs and memfd built in, so no kernel
modules are needed: Waydroid mounts binderfs itself at `/dev/binderfs` and only
then creates `/dev/binder`, `/dev/hwbinder` and `/dev/vndbinder`. AppArmor is
disabled on this host, so Waydroid's LXC profile runs unconfined.

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

# 3. start the session from your Wayland (Plasma) session
waydroid session start

# 4. launch the UI — prefer the "Waydroid" app-menu entry
waydroid show-full-ui          # may fail with
                               # "Failed to get service waydroidplatform"

# 5. apps (arm64-only images: no libhoudini/libndk bridge, so no 32-bit APKs)
waydroid app install foo.apk
waydroid app launch org.example.foo
waydroid shell
```

## Known limitations

* **Camera** does not work (removed from the image build).
* **Bluetooth** is non-functional (errors merely suppressed at build time).
* **No hardware video decode** — only software codecs are enabled.
* **Vulkan is off by default.** nixpkgs' Waydroid auto-detects
  `ro.hardware.gralloc=gbm`, `ro.hardware.egl=mesa` and
  `gralloc.gbm.device=/dev/dri/renderD128` for the asahi DRM node, but its
  `getVulkanDriver()` has no `asahi` (or `pastel`) case, so
  `ro.hardware.vulkan` is never set. These images ship
  `/vendor/lib64/hw/vulkan.pastel.so`, so the override would be:

  ```ini
  # /var/lib/waydroid/waydroid.cfg — after `waydroid init`, then restart
  # the session/container
  [properties]
  ro.hardware.vulkan=pastel
  ```

  It is left off by default because Vulkan in Android also needs
  `VK_ANDROID_native_buffer`, which this image was not verified to have
  (GLES/HWUI acceleration works without it).
* **Internal storage (`/sdcard`) is unreliable on btrfs**, and this host keeps
  `/home` on btrfs. Android's MediaProvider sets a project-quota xattr that
  btrfs rejects, so app downloads fail with `EPERM`. The workaround is to move
  Waydroid's data directory onto an ext4 loop image; `yuk1n0w`'s
  [`waydroid-storage`](https://github.com/yuk1n0w/waydroid-on-asahi)
  (`migrate-to-ext4`, plus a user service that re-runs `sm mount emulated` after
  each boot) implements exactly that. Copying APKs in with
  `waydroid app install` works without it.
* **No GApps** in these images (VANILLA build).
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
