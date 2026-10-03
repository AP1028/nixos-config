{
  config,
  pkgs,
  ...
}: let
  # Waydroid binds the session's data directory into the container as /data.
  dataDir = "${config.users.users.${config.local.username}.home}/.local/share/waydroid/data";
  dataImage = "/var/lib/waydroid/data.img";
in {
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

  # The Asahi kernel sets CONFIG_NETFILTER_XTABLES_LEGACY=n: it ships
  # nf_tables (plus nft_nat / nft_masq / nft_chain_nat) but no legacy
  # ip_tables modules, so the default build's `waydroid-net.sh start` dies
  # with "iptables ... can't initialize iptables table `filter': Table does
  # not exist".  nixpkgs only picks the nftables build when
  # networking.nftables is enabled; select it explicitly instead of moving
  # the whole host firewall to the nftables backend.
  virtualisation.waydroid.package = pkgs.waydroid-nftables;

  environment.etc."waydroid-extra/images/system.img".source = pkgs.fetchurl {
    url = "https://github.com/UtkarshVerma/waydroid-on-asahi/releases/download/lineage-23.0/system.img";
    hash = "sha256-0VUxvBdMpOun2q2WzICIuSMybEU4C2H1NWpZOcatUlI=";
  };

  environment.etc."waydroid-extra/images/vendor.img".source = pkgs.fetchurl {
    url = "https://github.com/UtkarshVerma/waydroid-on-asahi/releases/download/lineage-23.0/vendor.img";
    hash = "sha256-e8RkIdZAom+XPMd/XmYCJcguHs5AHilmQorgvrkN7EU=";
  };

  # The desktop entry runs plain `waydroid`, which only *shows* an already
  # running session (it never starts one), so the session manager has to be
  # started with the graphical session — the standard way other distros do it.
  home-manager.users.${config.local.username}.xdg.configFile."autostart/waydroid-session.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Waydroid Session
    Comment=Start the Waydroid session manager (Android in an LXC container)
    Exec=${config.virtualisation.waydroid.package}/bin/waydroid session start
    Terminal=false
    StartupNotify=false
    X-GNOME-Autostart-Phase=Applications
  '';

  # ── Android /data on ext4 instead of btrfs ───────────────────────────────
  #
  # Android's vold/MediaProvider stamp project-quota IDs on /data/media.
  # btrfs (this host's /home) refuses, so the emulated storage volume never
  # comes up: /storage/emulated/0 stays empty, /sdcard does not exist and
  # `sm list-volumes` prints nothing.  Giving the container a real ext4 /data
  # is the fix, so the session data directory lives on a loop image.
  #
  # The image is created -- and any existing data dir copied into it -- once by
  # waydroid-data-image.service; the mount unit then starts before
  # waydroid-container.service, which requires it.

  systemd.services.waydroid-data-image = {
    description = "Create/migrate the Waydroid Android /data ext4 loop image";
    wantedBy = ["multi-user.target"];
    path = [pkgs.coreutils pkgs.util-linux pkgs.e2fsprogs];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      img=${dataImage}
      mnt=${dataDir}
      mkdir -p "$(dirname "$img")" "$(dirname "$mnt")"

      if [ -e "$img" ]; then
        exit 0
      fi

      # Sparse 32 GiB image.  +C (nodatacow) keeps btrfs COW from fragmenting
      # the loop file; on other filesystems the chattr simply fails and is
      # ignored.
      truncate -s 32G "$img"
      chattr +C "$img" 2>/dev/null || true
      ${pkgs.e2fsprogs}/sbin/mkfs.ext4 -q -F -O quota,project -L waydroid-data "$img"

      # First run: move the existing btrfs data dir into the image, keeping the
      # old directory as <data>.btrfs-backup.
      if [ -d "$mnt" ]; then
        tmp=$(mktemp -d)
        mount -o loop "$img" "$tmp"
        if [ -n "$(ls -A "$mnt" 2>/dev/null || true)" ]; then
          cp -a "$mnt/." "$tmp/"
        fi
        umount "$tmp"
        rmdir "$tmp"
        bak="$mnt.btrfs-backup"
        n=1
        while [ -e "$bak" ]; do
          bak="$mnt.btrfs-backup.$n"
          n=$((n + 1))
        done
        mv "$mnt" "$bak" 2>/dev/null || true
      fi
      mkdir -p "$mnt"
    '';
  };

  systemd.mounts = [
    {
      what = dataImage;
      where = dataDir;
      type = "ext4";
      options = "loop,prjquota";
      wantedBy = ["multi-user.target"];
      requiredBy = ["waydroid-container.service"];
      after = ["waydroid-data-image.service"];
      requires = ["waydroid-data-image.service"];
      unitConfig = {
        Description = "Waydroid Android /data (ext4 loop image)";
        Before = ["waydroid-container.service"];
      };
    }
  ];

  # ── Vulkan: not available on these images (recorded so it isn't retried) ──
  #
  # The LineageOS 23.0 images set ro.hardware.vulkan=asahi but ship Mesa's
  # Asahi Vulkan driver as /vendor/lib64/hw/vulkan.pastel.so.  Making the file
  # the property names exist (aliasing vulkan.asahi.so -> vulkan.pastel.so in
  # the vendor overlay, which resolves and reads fine inside the container)
  # does *not* get it used: `cmd gpu vkjson` still reports the fallback
  # "SwiftShader Device (LLVM 16.0.0)".  The shipped library is a plain Mesa
  # ICD (it exports vk_icdGetInstanceProcAddr), not the Android HAL module the
  # loader wants, and ro.hardware.vulkan itself cannot be overridden from
  # waydroid.prop because the image sets it first and ro.* is write-once.
  # Software Vulkan (SwiftShader) is therefore what Android gets, while GLES is
  # hardware accelerated (SurfaceFlinger: "Mesa, Apple M2, OpenGL ES 3.2 Mesa
  # 26.0.6").  Hardware Vulkan needs an image built with Android's
  # VK_ANDROID_native_buffer support, e.g. the HLM319 LineageOS 23.2 tree --
  # nothing host-side can add it.

  # ── /sdcard (emulated storage) ───────────────────────────────────────────
  #
  # Under Waydroid vold never mounts the emulated storage volume by itself:
  # `dumpsys mount` reports VolumeInfo{emulated;0} state=UNMOUNTED path=null
  # until something calls `sm mount`.  `sm` is a Java command that needs
  # Android's full environment (BOOTCLASSPATH/ANDROID_*), which only
  # `waydroid shell` sets up -- through a plain `lxc-attach` it exits silently
  # and nothing happens.  This service keeps /sdcard mounted for as long as the
  # container runs, and deliberately leaves a frozen (idle) container alone.
  systemd.services.waydroid-storage = {
    description = "Mount Waydroid's emulated storage volume (/sdcard)";
    wantedBy = ["multi-user.target"];
    after = ["waydroid-container.service"];
    wants = ["waydroid-container.service"];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.lxc
      config.virtualisation.waydroid.package
    ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 15;
    };
    script = ''
      set -u
      while true; do
        # lxc-attach into a FROZEN container blocks (Android freezes itself
        # when idle), and unfreezing it just to look around would defeat
        # Waydroid's power saving, so only ever touch a RUNNING container.
        if ! lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH 2>/dev/null | grep -q '^RUNNING$'; then
          sleep 15
          continue
        fi
        vols=$(timeout 30 waydroid shell -- sm list-volumes all 2>/dev/null || true)
        if echo "$vols" | grep -qE '^emulated;[0-9]+ mounted'; then
          sleep 60
          continue
        fi
        vol=$(echo "$vols" | awk '/^emulated;[0-9]+/ {print $1; exit}')
        if [ -n "$vol" ]; then
          timeout 60 waydroid shell -- sm mount "$vol" >/dev/null 2>&1 || true
          # Let MediaProvider notice the new volume so apps see it immediately.
          timeout 60 waydroid shell -- content call --uri content://media \
            --method scan_volume --extra name:s:external_primary >/dev/null 2>&1 || true
        fi
        sleep 15
      done
    '';
  };
}
