# Steam on aarch64/Asahi — a NixOS port of Fedora Asahi Remix's
# `dnf install steam` stack (https://asahilinux.org/2024/10/aaa-gaming-on-asahi-linux/,
# https://pagure.io/fedora-asahi/steam).
#
# Fedora's stack is:
#   * Valve's official Steam bootstrap launcher (steam_*.tar.gz).  It downloads
#     and self-updates the x86_64 Steam client into ~/.local/share/Steam.
#   * FEX-Emu emulates x86/x86_64.
#   * muvm boots a 4K-page microVM because the Asahi kernel is 16K-page.
#   * the FEX project's official Fedora rootfs (what Fedora ships as
#     fex-emu-rootfs-fedora) provides the x86 userland.
#   * the launcher runs as: `muvm -- FEXBash -c '<launcher>/bin_steam.sh ...'`.
#
# NixOS has no /usr, /lib or Fedora /etc, and FEX's RootFS redirection
# (RootFS=/run/fex-emu/rootfs) makes Steam's pressure-vessel container
# creation fail on `/etc/host.conf` (bwrap: Can't get type of source) on this
# host.  So this package takes the same Fedora rootfs and, inside the muvm
# guest, bind-mounts it over /usr, /bin, /lib and /lib64 and over an /etc that
# stitched in the host user database, machine-id and DNS files.  FEX then only
# emulates instructions; every path is a real path, and Steam behaves as it
# does on Fedora.
#
# Known state (2026-09): the client, its update UI and the CEF steamwebhelper
# build a working window; the client UI (Store/library) has been verified.
# Launching games has not been exercised yet — see docs/steam-asahi.md.
{
  lib,
  stdenvNoCC,
  fetchurl,
  runCommand,
  erofs-utils,
  writeShellScript,
  writeShellScriptBin,
  symlinkJoin,
  coreutils,
  util-linux,
  dbus,
  fex,
  muvm,
  fonts ? [],
}: let
  # Valve's arch-independent bootstrap launcher (scripts + the ubuntu12_32
  # bootstrap tarball).  Steam itself updates from here on first run.
  steamLauncher = fetchurl {
    url = "https://repo.steampowered.com/steam/archive/stable/steam_1.0.0.87.tar.gz";
    hash = "sha256-ZJN10vk3f4AJqvPi/wmXgEHrkRSJfZxaOIbx2C4nuh8=";
  };

  # The FEX project's official Fedora 44 EROFS image.  Fedora's
  # fex-emu-rootfs-fedora RPM wraps this exact image.
  fexRootfsImage = fetchurl {
    url = "https://rootfs.fex-emu.gg/Fedora_44/2026-08-11/Fedora_44.ero";
    hash = "sha256-2yUDxP8kouDTmrFp0FoTqRICsm0uhzI0AMxRtGpuHFg=";
  };

  # Unpack it once into the store.  (FEX is *not* told about a RootFS; the
  # tree is bind-mounted at real paths in the guest instead.)
  fedoraRootfs = stdenvNoCC.mkDerivation {
    pname = "fex-fedora-rootfs";
    version = "44-2026-08-11";
    src = fexRootfsImage;
    nativeBuildInputs = [erofs-utils];
    dontUnpack = true;
    buildCommand = ''
      mkdir -p $out
      fsck.erofs --extract=$out --no-preserve-owner $src
      test -x $out/usr/bin/bash
      test -f $out/etc/host.conf

      # Steam's UI runs inside a pressure-vessel container that only gets
      # fonts from the guest's /usr/share/fonts (bound as /run/host/fonts),
      # so CJK fonts must physically live there.  The Fedora rootfs ships
      # Latin fonts only.
      mkdir -p $out/usr/share/fonts
      ${lib.concatMapStrings (font: ''
        if [ -d ${font}/share/fonts ]; then
          cp -r --no-preserve=mode ${font}/share/fonts/. $out/usr/share/fonts/
        fi
      '') fonts}
    '';
    meta = {
      description = "Fedora x86_64 root filesystem used by FEX-Emu (Asahi/Fedora)";
      homepage = "https://rootfs.fex-emu.gg/";
      platforms = ["aarch64-linux"];
    };
  };

  launcherDir = runCommand "steam-asahi-launcher" {
    meta.mainProgram = "bin_steam.sh";
  } ''
    mkdir -p $out
    tar xzf ${steamLauncher} -C $out
    chmod +x $out/steam-launcher/bin_steam.sh
    test -f $out/steam-launcher/bootstraplinux_ubuntu12_32.tar.xz
  '';

  # nixpkgs' fex 2608 only installs `FEX`; muvm's guest looks for the old
  # `FEXInterpreter` name when registering the binfmt handler.
  fexInterpreter = runCommand "fex-interpreter-compat" {} ''
    mkdir -p $out/bin
    ln -s ${fex}/bin/FEX $out/bin/FEXInterpreter
  '';

  # Runs as root inside the freshly booted muvm guest, before the user server
  # starts.  Makes the guest look like Fedora and keeps the host's user
  # database so Steam writes to the real $HOME.
  guestSetup = writeShellScript "steam-asahi-guest-setup" ''
    set -e
    M=${util-linux}/bin/mount
    CP=${coreutils}/bin/cp
    RM=${coreutils}/bin/rm
    MKDIR=${coreutils}/bin/mkdir

    # Steam + pressure-vessel want more inotify instances/watches than the
    # libkrun guest kernel's defaults.
    echo 8192 > /proc/sys/fs/inotify/max_user_instances || true
    echo 1048576 > /proc/sys/fs/inotify/max_user_watches || true

    # Save the host user database / machine identity before /etc is replaced.
    $CP /run/muvm-host/etc/passwd /run/passwd.host
    $CP /run/muvm-host/etc/group /run/group.host
    $CP /run/muvm-host/etc/shadow /run/shadow.host 2>/dev/null || true
    $CP /run/muvm-host/etc/hosts /run/hosts.host
    $CP /run/muvm-host/etc/machine-id /run/machine-id.host 2>/dev/null || true

    # Fedora userland at the real paths x86 binaries expect.
    $M --bind ${fedoraRootfs}/usr /usr
    $M --bind ${fedoraRootfs}/usr/bin /bin
    $M --bind ${fedoraRootfs}/usr/lib64 /lib64
    $M --bind ${fedoraRootfs}/usr/lib /lib

    # Fedora /etc + the host's passwd/group/shadow/machine-id.  (The rootfs
    # /etc has no passwd so muvm's user lookup must come from the host.)
    $MKDIR -p /run/etc-copy
    $CP -a ${fedoraRootfs}/etc/. /run/etc-copy/
    $CP /run/passwd.host /run/etc-copy/passwd
    $CP /run/group.host /run/etc-copy/group
    [ -e /run/shadow.host ] && $CP /run/shadow.host /run/etc-copy/shadow
    $CP /run/hosts.host /run/etc-copy/hosts
    [ -e /run/machine-id.host ] && $CP /run/machine-id.host /run/etc-copy/machine-id
    : > /run/etc-copy/resolv.conf

    # CJK and other host fonts: the Fedora rootfs ships Latin fonts only.
    # NixOS puts the host's font store paths in this conf; the Nix store is
    # shared with the guest, so copying the file in makes every host font
    # (Noto CJK, Sarasa, HarmonyOS, ...) visible to Steam, together with
    # NixOS's prebuilt font cache.
    if [ -e /run/muvm-host/etc/fonts/conf.d/00-nixos-cache.conf ]; then
      $CP /run/muvm-host/etc/fonts/conf.d/00-nixos-cache.conf \
        /run/etc-copy/fonts/conf.d/00-nixos-cache.conf
    fi

    $M --bind /run/etc-copy /etc

    # CEF/Steam expect a system bus (Fedora has one on the host).
    $MKDIR -p /run/dbus
    ${dbus}/bin/dbus-daemon --system --fork 2>/dev/null || true
  '';

  # muvm's main command: runs natively (aarch64) in the guest, provides a
  # session bus (Fedora's `dbus-x11`), then hands over to FEX.
  runtimeLauncher = writeShellScript "steam-asahi-runtime" ''
    set -e
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    addr=$(${dbus}/bin/dbus-daemon --session --fork --print-address 2>/dev/null || true)
    if [ -n "$addr" ]; then
      export DBUS_SESSION_BUS_ADDRESS="$addr"
    fi
    exec ${fex}/bin/FEXBash -c "${launcherDir}/steam-launcher/bin_steam.sh -cef-force-occlusion $*"
  '';

  # The user-facing entry point, the exact Fedora `steam` shim flow:
  #   muvm -x <guest setup> -- <runtime launcher>
  # with Fedora's PATH inside the guest (note: /usr/local/... first, and
  # FEXInterpreter last so muvm can register the binfmt handler).
  steam = writeShellScriptBin "steam" ''
    set -e
    if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
      echo "steam: XDG_RUNTIME_DIR is not set (run from a graphical session)" >&2
      exit 1
    fi
    # Give Steam its own microVM so it cannot collide with other muvm users
    # (e.g. cadence-env uses $XDG_RUNTIME_DIR/cadence-muvm).
    iso="$XDG_RUNTIME_DIR/steam-muvm"
    mkdir -p "$iso"
    chmod 700 "$iso"
    export XDG_RUNTIME_DIR="$iso"
    exec ${muvm}/bin/muvm \
      -x ${guestSetup} \
      -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${fexInterpreter}/bin \
      -e "HOME=$HOME" \
      -- ${runtimeLauncher} "$@"
  '';

  desktopItem = runCommand "steam-asahi-desktop" {} ''
    mkdir -p $out/share/applications $out/share/icons/hicolor
    cp ${launcherDir}/steam-launcher/steam.desktop $out/share/applications/steam.desktop
    # Valve's desktop file hardcodes /usr/bin/steam (Fedora's shim).  Point the
    # main entry and every desktop action at this package's steam wrapper.
    substituteInPlace $out/share/applications/steam.desktop \
      --replace-fail "/usr/bin/steam" "${steam}/bin/steam"
    for s in 16 24 32 48 256; do
      mkdir -p $out/share/icons/hicolor/''${s}x''${s}/apps
      cp ${launcherDir}/steam-launcher/icons/$s/steam.png \
        $out/share/icons/hicolor/''${s}x''${s}/apps/steam.png
    done
  '';
in
  symlinkJoin {
    name = "steam-asahi";
    paths = [
      (steam)
      desktopItem
    ];
    meta = {
      description = "Steam client on aarch64-linux via FEX-Emu + muvm (Fedora Asahi Remix stack)";
      homepage = "https://store.steampowered.com/";
      license = lib.licenses.unfreeRedistributable;
      platforms = ["aarch64-linux"];
      mainProgram = "steam";
    };
  }
