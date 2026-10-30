# Bottles on aarch64 (Asahi) — one self-contained module.
#
# ## Why this exists
#
# There is no upstream-supported way to run Bottles on Apple Silicon Linux.
# The Fedora Asahi Remix stack (muvm + FEX + Steam wrapper) only supports
# Steam/Proton: "we do not support running Windows apps outside of Steam as
# non-proton Wine not yet work on Fedora" (docs.fedoraproject.org/en-US/
# fedora-asahi-remix/x86-support). Flathub's com.usebottles.bottles is
# x86_64-only, nixpkgs' `bottles` cannot even evaluate on aarch64-linux (its
# multiArch buildFHSEnv needs pkgsi686Linux), and Bottles' own arm64 delivery
# is the cpak (OCI) package. So this module builds the missing integration:
#
#   Bottles (arm64, cpak image)
#     -> cpak sandbox (private rootfs, own IPC/mount/user namespaces)
#       -> muvm microVM (4 KiB pages, because FEX needs them)
#         -> host Mesa via muvm's DRM-native-context virtio-gpu
#
# ## The two bugs this module exists to fix
#
# 1. Black window. cpak's `displayX11` isolation starts a nested Xephyr for
#    the app, and runs the app in a *private IPC namespace*. Xephyr is in the
#    guest's namespace, so every SysV shared-memory transfer between the two
#    fails:
#
#        MESA: error: Failed to attach to x11 shm
#
#    Xephyr has no DRI3 either, so GTK4's GSK GL renderer runs on llvmpipe
#    and ends up presenting nothing — a pure-black 1280x800 window while the
#    app is alive. Forcing the cairo renderer removes the GL/SHM path
#    entirely; the UI is software-rendered either way (there is no GPU path
#    through Xephyr), so nothing is lost. Wine/DXVK rendering is unaffected:
#    that happens in the bottle's own process, not in GTK.
#
# 2. Lost data. cpak's manifest maps $HOME/.local/share/bottles and
#    $HOME/.local/share/icons from the host, but cpak launches the app with
#    XDG_DATA_HOME pointing at its own store, so Bottles wrote its library
#    into the ephemeral container layer and every launch looked like a fresh
#    install ("Library file not found. Creating new one."). Pointing the app's
#    XDG_DATA_HOME at the real $HOME/.local/share puts bottles, prefixes and
#    the library back in the mapped, persistent directory.
#
# ## The storage problem
#
# cpak composes the app root with a rootless OverlayFS mount. Inside muvm the
# guest root is virtiofs, which overlayfs refuses as an upperdir
# ("cannot mount overlay read-only"), and cpak's fuse-overlayfs fallback is
# only taken on EPERM/EACCES while /dev/fuse is 0600 root in the guest. So the
# whole cpak installation is put on a loop-mounted ext4 image that lives in
# the real $HOME: guestSetup attaches it from muvm's `-x` pre-command and
# CPAK_INSTALLATION_PATH points at it. Verified inside muvm:
#
#   [OK] unprivileged user namespaces / rootless OverlayFS / mount_setattr
#   [FAIL] Landlock: function not implemented   (optional; manifest disables it)
#
# Usage:
#   bottles-asahi-install     # first run: fetch Bottles into the guest store
#   bottles-asahi             # launch (GUI + Windows apps run in the microVM)
#   bottles-asahi --install   # later: update Bottles
#   bottles-asahi --debug     # same, with GSK/GDK renderer tracing
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.bottles-asahi;

  # Bottles' arm64 packaging is the cpak package at this origin.
  origin = "github.com/bottlesdevs/bottles";

  home = config.users.users.${config.local.username}.home;

  # Persisted across VM runs; the ext4 filesystem inside is what cpak's
  # overlay mounts actually use.
  stateDir = "${home}/.local/share/bottles-asahi";
  storeImage = "${stateDir}/store.img";

  # Guest-private paths; the persistence lives in storeImage.
  storeMount = "/run/bottles-asahi/store";
  cpakRoot = "${storeMount}/cpak";

  # XDG_RUNTIME_DIR subdirectory for this microVM's sockets, so it cannot
  # collide with steam-asahi's or cadence-env's.
  muvmRuntimeDir = "bottles-asahi-muvm";

  # Bottles' own data. The cpak manifest bind-mounts exactly these two host
  # directories; the app only reaches them when XDG_DATA_HOME points here.
  bottlesData = "${home}/.local/share/bottles";
  iconsData = "${home}/.local/share/icons";

  # Runs as root inside the freshly booted muvm guest (muvm -x), before the
  # user server starts. loop/mkfs/mount work here: the libkrunfw kernel is
  # built with CONFIG_BLK_DEV_LOOP=y and CONFIG_EXT4_FS=y, /dev is devtmpfs
  # and /dev/loop-control exists.
  guestSetup = pkgs.writeShellScript "bottles-asahi-guest-setup" ''
    set -eu
    MNT=${storeMount}
    IMG=${storeImage}

    ${pkgs.coreutils}/bin/mkdir -p "$MNT"
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$MNT"; then
      # Reuse an existing attachment if the image is already bound.
      loop=$(${pkgs.util-linux}/bin/losetup -j "$IMG" | ${pkgs.coreutils}/bin/cut -d: -f1 | ${pkgs.coreutils}/bin/head -1)
      if [ -z "$loop" ]; then
        loop=$(${pkgs.util-linux}/bin/losetup -f --show "$IMG")
      fi
      if ! ${pkgs.util-linux}/bin/blkid "$loop" >/dev/null 2>&1; then
        # No filesystem signature yet: first run, format it.
        ${pkgs.e2fsprogs}/bin/mkfs.ext4 -q -F "$loop"
      fi
      ${pkgs.util-linux}/bin/mount "$loop" "$MNT"
    fi

    # The wrapper creates the image as the invoking user, so its owner is the
    # uid/gid the guest user has (muvm keeps the host ids).
    owner=$(${pkgs.coreutils}/bin/stat -c '%u:%g' "$IMG")
    ${pkgs.coreutils}/bin/chown "$owner" "$MNT"
    ${pkgs.coreutils}/bin/chmod 755 "$MNT"

    # Bottles is inotify hungry; the libkrun guest defaults are much lower.
    echo 8192 > /proc/sys/fs/inotify/max_user_instances 2>/dev/null || true
    echo 1048576 > /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true
  '';

  # Runs as the invoking user inside the guest. Prepares the guest session and
  # hands the requested cpak subcommand the real binary.
  runtime = pkgs.writeShellScript "bottles-asahi-runtime" ''
    set -eu

    # cpak's whole installation must sit on the ext4 image, or its rootless
    # OverlayFS mount fails against the guest's virtiofs root.
    export CPAK_INSTALLATION_PATH=${cpakRoot}
    export XDG_DATA_HOME=${cpakRoot}/xdg-data
    export XDG_CACHE_HOME=${cpakRoot}/xdg-cache
    export XDG_STATE_HOME=${cpakRoot}/xdg-state
    ${pkgs.coreutils}/bin/mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"

    # muvm exposes X11 (its bridge to the host's XWayland) only: there is no
    # Wayland socket in the guest, so pin GTK to X11 and make cpak take its
    # Xephyr branch instead of looking for a Wayland compositor.
    unset WAYLAND_DISPLAY
    export GDK_BACKEND=x11

    # A session bus is expected by GTK/GApplication and by cpak's own
    # desktop-bus-proxy (it waits 3s for its upstream before giving up).
    addr=$(${pkgs.dbus}/bin/dbus-daemon --session --fork --print-address 2>/dev/null || true)
    if [ -n "$addr" ]; then
      export DBUS_SESSION_BUS_ADDRESS="$addr"
    fi

    # /run/current-system is symlinked into the guest by nixpkgs' muvm init
    # script, so the host system profile is usable here.
    export PATH="/run/current-system/sw/bin:/run/wrappers/bin:/usr/local/bin:/usr/bin:/bin"

    exec ${cfg.cpak}/bin/cpak "$@"
  '';

  # The user-facing entry point on the host.
  wrapper = pkgs.writeShellScriptBin "bottles-asahi" ''
    set -eu

    if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
      echo "bottles-asahi: XDG_RUNTIME_DIR is not set (run from a graphical session)" >&2
      exit 1
    fi

    action=run
    debug=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --install) action=install; shift ;;
        --debug) debug=1; shift ;;
        *) break ;;
      esac
    done

    # cpak's manifest bind-mounts these two host paths into the sandbox. They
    # must exist before the mount, or the mount is skipped and Bottles writes
    # its library into the ephemeral container layer.
    ${pkgs.coreutils}/bin/mkdir -p ${bottlesData} ${iconsData}

    # Create the store image as the invoking user so the guest can hand the
    # mount back to the right uid/gid. truncate makes it sparse.
    ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
    if [ ! -f ${storeImage} ]; then
      ${pkgs.coreutils}/bin/truncate -s ${cfg.storeSize} ${storeImage}
    fi

    # Keep this guest out of the way of steam-asahi/cadence-env microVMs.
    iso="$XDG_RUNTIME_DIR/${muvmRuntimeDir}"
    ${pkgs.coreutils}/bin/mkdir -p "$iso"
    ${pkgs.coreutils}/bin/chmod 700 "$iso"
    export XDG_RUNTIME_DIR="$iso"

    if [ "$action" = install ]; then
      exec ${pkgs.util-linux}/bin/flock -n -E 42 ${stateDir}/.lock \
        ${cfg.muvm}/bin/muvm \
        -x ${guestSetup} \
        -e "HOME=$HOME" \
        -- ${runtime} install -y ${origin} "$@"
    fi

    # Inside Xephyr the app has no DRI3, and cpak keeps it in its own IPC
    # namespace, so the GL renderer's shared-memory presentation fails and the
    # window stays black. cairo sidesteps that path; see the header comment.
    renderer="''${BOTTLES_GSK_RENDERER:-${cfg.gskRenderer}}"

    exec ${pkgs.util-linux}/bin/flock -n -E 42 ${stateDir}/.lock \
      ${cfg.muvm}/bin/muvm \
      -x ${guestSetup} \
      -e "HOME=$HOME" \
      -- ${runtime} run \
         --env "GSK_RENDERER=$renderer" \
         --env "XDG_DATA_HOME=$HOME/.local/share" \
         ''${debug:+--env GSK_DEBUG=renderer --env GDK_DEBUG=gl-debug} \
         ${origin} bottles "$@"
  '';

  installWrapper = pkgs.writeShellScriptBin "bottles-asahi-install" ''
    exec ${wrapper}/bin/bottles-asahi --install "$@"
  '';

  desktopItem = pkgs.runCommand "bottles-asahi-desktop" {} ''
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

  bottles = pkgs.symlinkJoin {
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
  };
in {
  options.programs.bottles-asahi = {
    enable = lib.mkEnableOption ''
      Bottles for aarch64-linux (Asahi): the upstream arm64 cpak package run
      under FEX in a muvm microVM. Only meaningful on aarch64-linux.
    '';

    cpak = lib.mkOption {
      type = lib.types.package;
      default = config.services.cpak.package;
      defaultText = lib.literalExpression "config.services.cpak.package";
      description = ''
        The cpak runtime used inside the guest. The guest store is written and
        read by one version only, so this defaults to the module's package
        rather than nixpkgs' `cpak`.
      '';
    };

    muvm = lib.mkOption {
      type = lib.types.package;
      default = pkgs.muvm;
      defaultText = lib.literalExpression "pkgs.muvm";
      description = "The muvm microVM runner used to get a 4 KiB-page guest.";
    };

    storeSize = lib.mkOption {
      type = lib.types.str;
      default = "64G";
      description = ''
        Maximum size of the sparse ext4 image holding the cpak store (Bottles,
        its Wine runner, FEX and the composed roots).
      '';
    };

    gskRenderer = lib.mkOption {
      type = lib.types.str;
      default = "cairo";
      description = ''
        GSK renderer forced for Bottles' own UI. The default `cairo` avoids the
        GL-over-Xephyr shared-memory path that produces a black window inside
        cpak's sandbox; the GUI is software rendered either way.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The cpak runtime: the it.cpak.SystemAuthority1 D-Bus/polkit service and
    # its systemd units.
    services.cpak.enable = true;

    # Asahi Mesa must be present in the guest (muvm passes the native context
    # through; the guest uses the host's /run/opengl-driver).
    hardware.graphics.enable = true;

    environment.systemPackages = [bottles];
  };
}
