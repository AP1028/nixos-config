{
  lib,
  stdenv,
  fetchurl,
  buildFHSEnv,
  writeShellScript,
  writeShellScriptBin,
  symlinkJoin,
  python3,
  callPackage,
  coreutils,
  pkgsCross,
  muvm,
}:

# Native ARM64 Steam client, ported "the Nix way".
#
# Valve ships an arm64 build of the Steam client (publicbeta-only as of
# 2026-09). It is a native aarch64 ELF — no FEX/muvm/box64 needed for the
# client itself — so unlike nixpkgs' x86_64 steam (which pulls in i686
# multilib and refuses to evaluate on aarch64) this one builds from a single
# arm64 FHS environment.
#
# The publicbeta manifest lives at
#   https://client-update.steamstatic.com/steam_client_publicbeta_linuxarm64
# The native arm64 client is packaged as `bins_linuxarm64_linuxarm64.zip`
# (which extracts to `steamrtarm64/`). Note the similarly-named
# `steam_steamrt_linuxarm64.zip`/`bins_steamrt_linuxarm64.zip` are the *x86_64*
# steamrt client (for FEX) — do NOT seed those. To update:
#   curl -s https://client-update.steamstatic.com/steam_client_publicbeta_linuxarm64 \
#     | grep -o '"file"[[:space:]]*"bins_linuxarm64_linuxarm64[^"]*"'
# then set the URL below and recompute the hash with:
#   nix hash file --type sha256 --sri <downloaded zip>
#
# NOTE: the client requires Armv8.1 + LSE atomics (fine on M1/M2+, which are
# Armv8.4+). It is also built for 4K pages, so on this 16K-page host it runs
# inside a muvm microVM (see `steam` below).

let
  # Dedicated x86_64 FEX rootfs for this VM's FEX-Emu tool. Kept separate
  # from cadence-env's fex-cadence-rootfs on purpose (see the header of
  # steam-arm64-fex-rootfs.nix) — the two VMs must stay independently
  # updatable, so both copies exist side by side.
  steam-arm64-fex-rootfs = callPackage ./steam-arm64-fex-rootfs.nix { };

  # Guest-side root setup, run by muvm (-x) before the Steam command. The
  # guest / is the host's, shared read-only, so /usr itself cannot be written
  # (cadence-env works around the same thing by mounting tmpfs over /bin).
  # Shadow /usr with a tmpfs and recreate the bits the guest needs: Valve's
  # fex-compat-tool hardcodes /usr/share/guestos/fex-mesa as the FEX rootfs
  # (a SteamOS guest-image convention; g_fex_rootfs_with_mesa in that
  # script) — expose the muvm-mounted rootfs there so the per-app
  # Config.json it writes (RootFS=/usr/share/guestos/fex-mesa/) points at a
  # real rootfs — and /usr/bin/env, because fex-compat-tool itself is a
  # `#!/usr/bin/env python3` script.
  steam-arm64-guest-setup = writeShellScript "steam-arm64-guest-setup" ''
    mount -t tmpfs tmpfs /usr
    mkdir -p /usr/bin /usr/share/guestos
    ln -sf ${coreutils}/bin/env /usr/bin/env
    ln -sfn /run/fex-emu/rootfs /usr/share/guestos/fex-mesa

    # Valve's launch chain hands shell scripts (_v2-entry-point, proton) to
    # the depot FEX, which resolves a script's shebang interpreter through
    # the FEX rootfs and requires an x86 ELF there. The merged rootfs takes
    # /bin from the guest (arm64 sh), which fails with "Invalid or
    # Unsupported elf file" — shadow it with x86 shells. muvm mounts the
    # rootfs before running this script, and the erofs cannot shadow /bin
    # (only /usr and /lib64 are overlaid), so a tmpfs is the only hook.
    mount -t tmpfs tmpfs /run/fex-emu/rootfs/bin
    ln -sf ${pkgsCross.gnu64.bash}/bin/bash /run/fex-emu/rootfs/bin/bash
    ln -sf bash /run/fex-emu/rootfs/bin/sh
    ln -sf ${pkgsCross.gnu64.coreutils}/bin/env /run/fex-emu/rootfs/bin/env

    # The emulated x86 side reads the ld.so cache through the rootfs, but
    # rootfs /var is a bind of the host /var, where NixOS keeps
    # /var/cache/ldconfig root-only (drwx------). PV's x86
    # capsule-capture-libs treats an unreadable AND a missing cache as
    # fatal, so shadow the dir with a writable tmpfs and seed it with the
    # platform tree's own x86 cache — the same thing Valve's guestos rootfs
    # ships; its entry paths resolve inside the container where SLR4 is
    # mounted at their absolute paths. Same for the root-only /root.
    mount -t tmpfs tmpfs /run/fex-emu/rootfs/var/cache/ldconfig
    chmod 755 /run/fex-emu/rootfs/var/cache/ldconfig
    for c in /home/tianyixia/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/steamrt4_platform_*/files/etc/ld.so.cache; do
      if [ -r "$c" ]; then
        cp "$c" /run/fex-emu/rootfs/var/cache/ldconfig/ld.so.cache
        chmod 644 /run/fex-emu/rootfs/var/cache/ldconfig/ld.so.cache
        break
      fi
    done
    mount -t tmpfs tmpfs /run/fex-emu/rootfs/root
    chmod 755 /run/fex-emu/rootfs/root

    # SLR4 selects its NATIVE arm64 pressure-vessel only when
    # STEAM_COMPAT_GRAPHICS_PROVIDER points at an existing file (without it,
    # the x86 PV runs under FEX and trips over rootfs-translated host paths
    # like /etc/machine-id). fex-compat-tool, in turn, derives the FEX rootfs
    # from dirname(STEAM_COMPAT_GRAPHICS_PROVIDER) — so the marker file must
    # live INSIDE the rootfs, making /run/fex-emu/rootfs the RootFS
    # everywhere, i.e. the one path PV actually binds into the container (it
    # refuses anything under /usr). The json itself is minimal: PV falls
    # back to auto-discovering the host GPU when it declares nothing. Also
    # seed the rootfs /etc for the x86-PV fallback path.
    echo '{"graphics_provider_v0": {"architectures": {"x86_64-linux-gnu": {}}}}' > /run/fex-emu/rootfs/graphics_provider.json
    if [ ! -e /run/fex-emu/rootfs/etc/machine-id ]; then
      mount -t tmpfs tmpfs /run/fex-emu/rootfs/etc
      cp /etc/resolv.conf /run/fex-emu/rootfs/etc/resolv.conf 2>/dev/null || true
      cp /etc/machine-id /run/fex-emu/rootfs/etc/machine-id 2>/dev/null || true
    fi
  '';

  # Valve's favicon, reused as the app icon (the client zip ships none).
  steam-icon = fetchurl {
    url = "https://store.steampowered.com/favicon.ico";
    hash = "sha256-n4kKnevN/MwzkUmnlDvpr/nkySA8L6N9VnGlssiFA60=";
  };

  # Read-only seed: the native arm64 client. The launcher copies this into
  # ~/.local/share/Steam/steamrtarm64 on first run, where Steam then
  # self-updates (the store copy is never written back to).
  steam-arm64-unwrapped = stdenv.mkDerivation {
    pname = "steam-arm64-unwrapped";
    version = "2026-09-01";

    src = fetchurl {
      url = "https://client-update.steamstatic.com/bins_linuxarm64_linuxarm64.zip.e59e82a5b6cbba6452d024d661c46e302b90376f";
      hash = "sha256-kvtviwIwcTyptHtzu/hXayBFy96UdGKmmG2SLFxbFa0=";
    };

    nativeBuildInputs = [ python3 ];

    # Proprietary binaries; don't strip or rewrite their ELF headers.
    dontStrip = true;
    dontPatchELF = true;
    # The source is a zip; extract it ourselves in installPhase (Python's
    # zipfile, not Info-ZIP, to handle the Windows backslash path separators).
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/steam"
      ${python3}/bin/python3 ${./steam-arm64-extract.py} "$src" "$out/lib/steam"

      # The zip records exec bits for the client itself but not for every
      # helper binary; ensure the entry points are runnable.
      chmod +x "$out/lib/steam/steamrtarm64/steam" \
                "$out/lib/steam/steamrtarm64/steamwebhelper" \
                "$out/lib/steam/steamrtarm64/steamwebhelper.sh" \
                "$out/lib/steam/steamrtarm64/gldriverquery" \
                "$out/lib/steam/steamrtarm64/vulkandriverquery" \
                "$out/lib/steam/steamrtarm64/steamsysinfo" \
                "$out/lib/steam/steamrtarm64/steam_monitor" \
                "$out/lib/steam/steamrtarm64/steamerrorreporter" \
                "$out/lib/steam/steamrtarm64/reaper" \
                "$out/lib/steam/steamrtarm64/gameoverlayui" \
                "$out/lib/steam/steamrtarm64/fossilize_replay" \
                "$out/lib/steam/steamrtarm64/vgui_panel_zoo" \
                "$out/lib/steam/steamrtarm64/streaming_client"

      # Desktop entry + icon (the client zip ships neither; mirror what the
      # x86_64 steam-unwrapped bootstrap installs).
      mkdir -p "$out/share/applications" "$out/share/pixmaps" \
               "$out/share/icons/hicolor/256x256/apps"
      cp ${./steam-arm64.desktop} "$out/share/applications/steam.desktop"
      ${python3}/bin/python3 ${./steam-arm64-icon.py} \
        ${steam-icon} "$out/share/icons/hicolor/256x256/apps/steam.png"
      cp "$out/share/icons/hicolor/256x256/apps/steam.png" "$out/share/pixmaps/steam.png"
      runHook postInstall
    '';

    meta = with lib; {
      description = "Steam client, Valve's native arm64 build (publicbeta)";
      homepage = "https://store.steampowered.com/";
      license = licenses.unfreeRedistributable;
      platforms = [ "aarch64-linux" ];
    };
  };

  # The FHS-wrapped native client: runs the aarch64 client in a standard FHS
  # layout (glibc loader at /lib/ld-linux-aarch64.so.1, X11/glib/... libs at
  # /usr/lib). On a 4K-page arm64 host it would run directly; here it is
  # launched inside muvm below.
  steam-fhs = buildFHSEnv {
  pname = "steam-arm64";
  version = steam-arm64-unwrapped.version;
  executableName = "steam";

  # arm64 only: no i686 multilib, so multiArch must stay off.
  multiArch = false;
  includeClosures = true;

  # Command-line tools Steam shells out to (mirrors nixpkgs' steam, minus the
  # x86-only glibc_multi.bin). lsof is hard-required: GetIPCConnectionDetails
  # uses it to authenticate the steamui websocket, and without it startup
  # fails with "unexpected error during startup: 0x3009".
  targetPkgs = pkgs: with pkgs; [
    bash
    coreutils
    file
    lsb-release
    lsof
    pciutils
    usbutils
    util-linux # taskset, used by steamwebhelper.sh
    xdg-utils
    xz
    zenity

    # crashes on startup if it can't find libX11 locale files
    (pkgs.runCommand "xorg-locale" { } ''
      mkdir -p "$out"
      ln -s ${libx11}/share "$out/share"
    '')
  ];

  # Host libraries the client runtime links (mirrors nixpkgs' steam multiPkgs,
  # plus the arm64 client's extra needs: SDL2/SDL3, gtk2/gdk-pixbuf, ibus,
  # pipewire/openal/pulse, libvpx/brotli).
  multiPkgs = pkgs: with pkgs; [
    glibc
    libxcrypt
    libGL

    libdrm
    libgbm
    udev
    libudev0-shim
    libva
    vulkan-loader
    libcap

    libx11
    libxi
    libxext
    libxrender
    libxtst
    libxrandr
    libxcomposite
    libxdamage
    libxfixes
    libxcursor
    libxcb
    libxinerama
    libsm
    libice
    libxkbcommon

    fontconfig
    freetype
    expat

    glib
    gtk2
    gtk3 # steamwebhelper/libcef: libgtk-3.so.0 (closure: atk, pango, cairo)
    gdk-pixbuf

    # Tray icon: the client dlopens libappindicator.so.1 (StatusNotifierItem
    # on the session bus) but doesn't bundle it. Without it the tray icon
    # silently fails to appear, so closing the window leaves Steam running
    # with nothing in the KDE panel to quit it from.
    libappindicator-gtk3

    # steamwebhelper/libcef (Chromium): nss is the lib it failed on first
    # (libnss3.so), plus dbus, cups, alsa, curl probed at startup.
    nss
    nspr
    dbus
    cups
    alsa-lib
    curl

    pipewire
    libpulseaudio
    openal

    networkmanager # libnm.so.0

    ibus # libibus-1.0.so.5

    brotli
    libvpx

    SDL2 # gldriverquery
    sdl3 # steamwebhelper / steamui
    sdl3-image # streaming_client
    sdl3-ttf # streaming_client
  ];

  profile = ''
    unset GIO_EXTRA_MODULES
    export SDL_JOYSTICK_DISABLE_UDEV=1
    export GTK_IM_MODULE='xim'

    export LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri
    export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
    export LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri
    export VDPAU_DRIVER_PATH=/run/opengl-driver/lib/vdpau

    # This is an Apple Silicon (Asahi) GPU; force the asahi driver so mesa
    # doesn't try (and fail on) radv/amdgpu and fall back to llvmpipe.
    export MESA_LOADER_DRIVER_OVERRIDE=asahi

    if [ -z ''${TZ+x} ]; then
      new_TZ="$(readlink -f /etc/localtime | grep -P -o '(?<=/zoneinfo/).*$')"
      if [ $? -eq 0 ]; then
        export TZ="$new_TZ"
      fi
    fi
  '';

  # Steam expects /sbin/ldconfig to exist; copy it (see nixpkgs steam).
  extraBuildCommands = ''
    cp -f "$out"/usr/{bin,sbin}/ldconfig

    # The game's FEX chain runs inside this bubblewrap container, whose /usr
    # is built from multiPkgs — the guest-level /usr/share/guestos symlink
    # (-x setup script) is not visible here. Valve's fex-compat-tool
    # hardcodes /usr/share/guestos/fex-mesa as the FEX rootfs, so publish it
    # in this container as well; the target is bind-mounted in through
    # extraBwrapArgs below.
    mkdir -p "$out/usr/share/guestos"
    ln -s /run/fex-emu/rootfs "$out/usr/share/guestos/fex-mesa"
  '';

  extraInstallCommands = ''
    ln -s ${steam-arm64-unwrapped}/share "$out/share"
  '';

  extraBwrapArgs = [
    "--bind-try /tmp/dumps /tmp/dumps"
    # FEX rootfs (mounted by muvm at /run/fex-emu/rootfs, see the -f flag)
    # reachable from inside the FHS env for the game's FEX chain. The
    # graphics-provider marker file lives inside the rootfs, so it comes
    # along with this bind.
    "--bind-try /run/fex-emu/rootfs /run/fex-emu/rootfs"
  ];

  runScript = writeShellScript "steam-arm64-run" ''
    set -eu

    steam_root="$HOME/.local/share/Steam"
    client_dir="$steam_root/steamrtarm64"

    mkdir -p "$steam_root"

    # Seed the mutable client copy from the read-only store on first run (or
    # if a previous seed is incomplete). Steam self-updates this directory
    # afterwards, so leave it alone once it's in place.
    if [ ! -x "$client_dir/steam" ]; then
      rm -rf "$client_dir"
      cp -r ${steam-arm64-unwrapped}/lib/steam/steamrtarm64 "$client_dir"
      chmod -R u+rwx "$client_dir"
    fi

    # arm64 builds are only on the publicbeta channel right now.
    mkdir -p "$steam_root/package"
    printf 'publicbeta\n' > "$steam_root/package/beta"

    # ~/.steam symlinks point Steam at its install/data root. steam.sh's
    # bootstrap normally creates sdkarm64 (-> linuxarm64, holding
    # steam-launch-wrapper + steamclient.so); since we launch the binary
    # directly, create it here or every game launch dies instantly with
    # "/bin/sh: .steam/sdkarm64/steam-launch-wrapper: No such file or
    # directory".
    mkdir -p "$HOME/.steam"
    ln -sfn "$steam_root" "$HOME/.steam/steam"
    ln -sfn "$steam_root" "$HOME/.steam/root"
    ln -sfn "$steam_root/linuxarm64" "$HOME/.steam/sdkarm64"

    # Run the native client directly. Its updater exits with code 42
    # (MAGIC_RESTART) after installing an update, so honour that by
    # re-launching with the freshly-installed client. `|| status=$?` keeps
    # the non-zero exit away from `set -e`, which would otherwise kill this
    # script on the spot and turn every self-update into a dead terminal.
    while true; do
      status=0
      "$client_dir/steam" "$@" 2> "$HOME/steam_client_stderr.log" || status=$?
      [ "$status" -eq 42 ] || exit "$status"
    done
  '';

  meta = {
    description = "Steam client for aarch64-linux (Valve's native arm64 build)";
    homepage = "https://store.steampowered.com/";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "aarch64-linux" ];
    mainProgram = "steam";
  };
};
# The native client is compiled for 4K pages, but this host runs a 16K-page
# kernel (Apple Silicon), so its ELF LOAD segments can't be mapped by the
# host. Run the whole FHS env inside a 4K-page muvm microVM; the client runs
# natively there, and the host GPU/display are bridged through by muvm.
# x86_64 games are handled by the client itself (FEX-Emu compat tool →
# Steam Linux Runtime 4 → Proton), which needs a FEX rootfs: pass
# steam-arm64-fex-rootfs to muvm (-f) and publish it at the Valve-hardcoded
# /usr/share/guestos/fex-mesa path in the guest (-x script).
steam = symlinkJoin {
  name = "steam-arm64";
  paths = [
    (writeShellScriptBin "steam" ''
      # muvm reuses a single per-user microVM, keyed on XDG_RUNTIME_DIR. Other
      # tools (e.g. cadence-env) occupy that VM with a FEX rootfs, so give
      # Steam its own VM via a dedicated runtime dir, and hand the real
      # runtime dir into the guest for wayland/dbus/pulse sockets.
      if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
        echo "steam: XDG_RUNTIME_DIR is not set (run from a graphical session)" >&2
        exit 1
      fi
      real_runtime="$XDG_RUNTIME_DIR"
      iso_runtime="$real_runtime/steam-muvm"
      mkdir -p "$iso_runtime"
      chmod 700 "$iso_runtime"

      # Pass through the GUI-session environment, skipping vars that aren't
      # set (muvm's `-e KEY` errors on unset vars, e.g. XDG_CONFIG_HOME in a
      # bare terminal).
      env_flags=()
      for v in DISPLAY XAUTHORITY HOME DBUS_SESSION_BUS_ADDRESS \
               WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
               XDG_DATA_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME; do
        if [ -n "''${!v:-}" ]; then
          env_flags+=(-e "$v")
        fi
      done

      # The game's FEX runs inside the SLR4 pressure-vessel container, whose
      # /usr is the Steam runtime's tree — the guest-level
      # /usr/share/guestos/fex-mesa symlink is invisible there (and PV
      # refuses to bind anything under /usr). Point the compat tool's
      # STEAM_COMPAT_GRAPHICS_PROVIDER at a file inside /run/fex-emu/rootfs:
      # it derives the FEX rootfs from dirname(provider), making
      # /run/fex-emu/rootfs the RootFS everywhere, and SLR4 uses its native
      # arm64 pressure-vessel when the provider file exists.
      export STEAM_COMPAT_GRAPHICS_PROVIDER="/run/fex-emu/rootfs/graphics_provider.json"
      export STEAM_COMPAT_MOUNTS="/run/fex-emu/rootfs''${STEAM_COMPAT_MOUNTS:+:$STEAM_COMPAT_MOUNTS}"

      XDG_RUNTIME_DIR="$iso_runtime" \
        exec ${muvm}/bin/muvm "''${env_flags[@]}" \
          -e "XDG_RUNTIME_DIR=$real_runtime" \
          -e "STEAM_COMPAT_MOUNTS=$STEAM_COMPAT_MOUNTS" \
          -e "STEAM_COMPAT_GRAPHICS_PROVIDER=$STEAM_COMPAT_GRAPHICS_PROVIDER" \
          -f ${steam-arm64-fex-rootfs} \
          -m \
          -x ${steam-arm64-guest-setup} \
          -- ${steam-fhs}/bin/steam "$@"
    '')
    steam-fhs
  ];
  meta = {
    description = "Steam client for aarch64-linux (native arm64 build in a 4K-page muvm)";
    homepage = "https://store.steampowered.com/";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "aarch64-linux" ];
    mainProgram = "steam";
  };
};
in
steam
