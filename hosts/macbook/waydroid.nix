{pkgs, ...}: {
  # ── Waydroid: Android 16 (LineageOS 23.0) in an LXC container ────────────
  #
  # Apple Silicon needs 16 KiB kernel pages (the IOMMUs and GPU only work with
  # them, so a 4 KiB kernel -- the obvious workaround -- is not an option).
  # Upstream Waydroid images are 4 KiB builds whose bionic linker and
  # page-size macros do not survive on a 16 KiB kernel.  muvm's 4 KiB microVM
  # does not help here either: Waydroid needs a full LXC-capable system, and
  # the Android image is what carries the Mesa build Waydroid renders with.
  #
  # Instead this pins the prebuilt LineageOS 23.0 images from the
  # waydroid-on-asahi project, built with PRODUCT_MAX_PAGE_SIZE_SUPPORTED :=
  # 16384 and Mesa's asahi (gallium) + pastel (Vulkan) drivers.  Verified on
  # import: every ELF PT_LOAD segment is 0x4000-aligned, Android 16 / SDK 36.
  #
  # The images land in /etc/waydroid-extra/images, one of Waydroid's
  # `preinstalled_images_paths`.  Waydroid then uses them verbatim: it never
  # contacts ota.waydro.id (whose newest arm64 image is still LineageOS 20)
  # and disables the in-Android updater, so these 16 KiB images cannot be
  # replaced by 4 KiB ones.
  #
  # nixpkgs ships Waydroid 1.6.3, the first release that supports Android 16
  # images.  First-run steps and known limitations: docs/waydroid-asahi.md.

  virtualisation.waydroid.enable = true;

  environment.etc."waydroid-extra/images/system.img".source = pkgs.fetchurl {
    url = "https://github.com/UtkarshVerma/waydroid-on-asahi/releases/download/lineage-23.0/system.img";
    hash = "sha256-0VUxvBdMpOun2q2WzICIuSMybEU4C2H1NWpZOcatUlI=";
  };

  environment.etc."waydroid-extra/images/vendor.img".source = pkgs.fetchurl {
    url = "https://github.com/UtkarshVerma/waydroid-on-asahi/releases/download/lineage-23.0/vendor.img";
    hash = "sha256-e8RkIdZAom+XPMd/XmYCJcguHs5AHilmQorgvrkN7EU=";
  };
}
