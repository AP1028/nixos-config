# Bottles under muvm on Asahi (aarch64, 16 KiB pages).
#
# Bottles' ARM64 build exists only as a cpak (OCI image) package. Used
# directly on this host (modules/packages/bottles-cpak.nix) the GUI works, but
# the Windows side needs FEX, and FEX only runs on a 4 KiB-page kernel — i.e.
# inside muvm's microVM, exactly like programs.steam-asahi.
#
# cpak cannot simply be launched inside muvm, though: when an application
# starts, cpak composes its root with a *rootless OverlayFS* mount, and
# overlayfs refuses the muvm guest's root filesystem (virtiofs, a FUSE-derived
# filesystem with d_revalidate) as an upperdir:
#
#     [FAIL] rootless OverlayFS: ... cannot mount overlay read-only   # inside muvm
#
# The fix is to put cpak's installation on a filesystem overlayfs accepts: a
# loop-mounted ext4 image. The image lives in the real $HOME (so installed
# applications and their state survive across VM runs), guest root attaches it
# from the `-x` pre-command, and CPAK_INSTALLATION_PATH points cpak's whole
# installation (store, layers, composed roots, cache, exports) at it.
# Verified inside muvm with this setup:
#
#     [OK] unprivileged user namespaces: ... can be created
#     [OK] rootless OverlayFS: overlay mount with userxattr succeeded in a user namespace
#     [OK] mount_setattr / seccomp / X11 display / PipeWire
#     [FAIL] Landlock: function not implemented
#
# Landlock is the only failure: the libkrunfw guest kernel is built without an
# LSM. cpak documents Landlock as an optional hardening layer, and Bottles'
# manifest explicitly disables it, so this does not affect running Bottles.
#
# The bottled Windows prefixes are *not* in the image: the manifest maps
# home/.local/share/bottles, so they stay in the real $HOME as usual.
{
  lib,
  writeShellScript,
  writeShellScriptBin,
  symlinkJoin,
  runCommand,
  util-linux,
  e2fsprogs,
  coreutils,
  dbus,
  muvm,
  cpak,
  home,
}: let
  origin = "github.com/bottlesdevs/bottles";

  # Persisted across VM runs; the ext4 filesystem inside is what cpak's
  # overlay mounts actually use.
  stateDir = "${home}/.local/share/bottles-asahi";
  storeImage = "${stateDir}/store.img";
  storeSize = "64G";

  # Guest-private path; the persistence lives in storeImage, not here.
  storeMount = "/run/bottles-asahi/store";
  cpakRoot = "${storeMount}/cpak";

  # Runs as root inside the freshly booted muvm guest (muvm -x), before the
  # guest user server starts. Attaches the ext4 image and hands the mount to
  # the invoking user. loop/mkfs work here: the libkrunfw kernel is built with
  # CONFIG_BLK_DEV_LOOP=y and CONFIG_EXT4_FS=y, /dev is devtmpfs and there is
  # a /dev/loop-control node.
  guestSetup = writeShellScript "bottles-asahi-guest-setup" ''
    set -eu
    MNT=${storeMount}
    IMG=${storeImage}

    ${coreutils}/bin/mkdir -p "$MNT"
    if ! ${util-linux}/bin/mountpoint -q "$MNT"; then
      # Reuse an existing attachment if the image is already bound.
      loop=$(${util-linux}/bin/losetup -j "$IMG" | ${coreutils}/bin/cut -d: -f1 | ${coreutils}/bin/head -1)
      if [ -z "$loop" ]; then
        loop=$(${util-linux}/bin/losetup -f --show "$IMG")
      fi
      if ! ${util-linux}/bin/blkid "$loop" >/dev/null 2>&1; then
        # No filesystem signature yet: first run, format it.
        ${e2fsprogs}/bin/mkfs.ext4 -q -F "$loop"
      fi
      ${util-linux}/bin/mount "$loop" "$MNT"
    fi

    # The wrapper creates the image as the invoking user, so its owner is the
    # uid/gid the guest user has (muvm keeps the host ids).
    owner=$(${coreutils}/bin/stat -c '%u:%g' "$IMG")
    ${coreutils}/bin/chown "$owner" "$MNT"
    ${coreutils}/bin/chmod 755 "$MNT"

    # Bottles' WebKit/CEF-ish helpers are inotify hungry; the libkrun guest
    # defaults are much lower.
    echo 8192 > /proc/sys/fs/inotify/max_user_instances 2>/dev/null || true
    echo 1048576 > /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true
  '';

  # Runs as the invoking user inside the guest. Prepares the guest session and
  # hands the requested cpak subcommand to the real binary, so both `install`
  # and `run` share it.
  runtime = writeShellScript "bottles-asahi-runtime" ''
    set -eu

    # cpak's whole installation must sit on the ext4 image, or its rootless
    # OverlayFS mount fails against the guest's virtiofs root.
    export CPAK_INSTALLATION_PATH=${cpakRoot}
    export XDG_DATA_HOME=${cpakRoot}/xdg-data
    export XDG_CACHE_HOME=${cpakRoot}/xdg-cache
    export XDG_STATE_HOME=${cpakRoot}/xdg-state
    ${coreutils}/bin/mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${coreutils}/bin/id -u)}"

    # muvm exposes X11 (XWayland) only: no Wayland socket exists in the guest,
    # so pin GTK to its X11 backend instead of letting it probe.
    unset WAYLAND_DISPLAY
    export GDK_BACKEND=x11

    # A session bus is expected by GTK/GApplication and by cpak's own helpers.
    addr=$(${dbus}/bin/dbus-daemon --session --fork --print-address 2>/dev/null || true)
    if [ -n "$addr" ]; then
      export DBUS_SESSION_BUS_ADDRESS="$addr"
    fi

    # /run/current-system is symlinked into the guest by nixpkgs' muvm init
    # script, so the host system profile is usable here.
    export PATH="/run/current-system/sw/bin:/run/wrappers/bin:/usr/local/bin:/usr/bin:/bin"

    exec ${cpak}/bin/cpak "$@"
  '';

  # muvm only runs one guest at a time on this host, and two guests must never
  # attach the same ext4 image. Hold an exclusive lock for the lifetime of the
  # guest (flock exits 42 when the lock is already held).
  lockFile = "${stateDir}/.lock";

  wrapper = writeShellScriptBin "bottles-asahi" ''
    set -eu

    if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
      echo "bottles-asahi: XDG_RUNTIME_DIR is not set (run from a graphical session)" >&2
      exit 1
    fi

    action=run
    if [ "''${1:-}" = "--install" ]; then
      action=install
      shift
    fi

    # Create the store image as the invoking user so the guest can hand the
    # mount back to the right uid/gid. truncate makes it sparse.
    ${coreutils}/bin/mkdir -p ${stateDir}
    if [ ! -f ${storeImage} ]; then
      ${coreutils}/bin/truncate -s ${storeSize} ${storeImage}
    fi

    # Keep this guest out of the way of steam-asahi/cadence-env microVMs.
    iso="$XDG_RUNTIME_DIR/bottles-asahi-muvm"
    ${coreutils}/bin/mkdir -p "$iso"
    ${coreutils}/bin/chmod 700 "$iso"
    export XDG_RUNTIME_DIR="$iso"

    if [ "$action" = install ]; then
      exec ${util-linux}/bin/flock -n -E 42 ${lockFile} \
        ${muvm}/bin/muvm \
        -x ${guestSetup} \
        -e "HOME=$HOME" \
        -- ${runtime} install -y ${origin} "$@"
    fi

    exec ${util-linux}/bin/flock -n -E 42 ${lockFile} \
      ${muvm}/bin/muvm \
      -x ${guestSetup} \
      -e "HOME=$HOME" \
      -- ${runtime} run ${origin} bottles "$@"
  '';

  installWrapper = writeShellScriptBin "bottles-asahi-install" ''
    exec ${wrapper}/bin/bottles-asahi --install "$@"
  '';

  desktopItem = runCommand "bottles-asahi-desktop" {} ''
    mkdir -p $out/share/applications
    cat > $out/share/applications/bottles-asahi.desktop <<EOF
    [Desktop Entry]
    Type=Application
    Name=Bottles (muvm)
    Comment=Run Windows software with Bottles inside a 4K-page microVM
    Exec=${wrapper}/bin/bottles-asahi
    Terminal=false
    Categories=Utility;Game;Emulator;
    Keywords=wine;windows;gaming;
    Icon=application-x-executable
    EOF
  '';
in
  symlinkJoin {
    name = "bottles-asahi";
    paths = [
      wrapper
      installWrapper
      desktopItem
    ];
    meta = {
      description = "Bottles on aarch64-linux via cpak + FEX inside muvm (Asahi)";
      homepage = "https://usebottles.com/";
      license = lib.licenses.gpl3Only;
      platforms = ["aarch64-linux"];
      mainProgram = "bottles-asahi";
    };
  }
