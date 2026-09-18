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
  pkgs,
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

    # The x86 /bin shadow (x86 sh/bash/env for Valve's scripts) and the
    # emulated side's ld.so.cache now come from a SECOND FEX rootfs image,
    # built by the host-side steam wrapper and passed as an overlay
    # (muvm -f base -f overlay, see "FEX rootfs overlay" there).
    #
    # Why not mounts here: muvm's merged rootfs tolerates only ONE tmpfs
    # mount below the FEX rootfs — with two, the VM silently stops running
    # the main command (verified: bin+cache mounts => main command never
    # runs; either one alone is fine). The rootfs erofs itself is read-only
    # (writing /run/fex-emu/rootfs/etc/* fails with EACCES, and /var is a
    # root-only bind of the host /var). The overlay image mechanism avoids
    # all of it and lets the wrapper put the platform's cache at exactly the
    # paths the emulated loader reads.
    # NOTE: only ONE tmpfs mount below the FEX rootfs is possible — with two
    # (e.g. /etc and /root) the VM silently stops running the main command
    # and the client never starts. The /etc mount below is the valuable one:
    # it makes the emulated loader's cache writable. The old /root shadow was
    # dropped for it.

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
    # The provider must cover BOTH architectures. The game is x86_64, but the
    # GL/Vulkan calls are thunked by FEX into arm64 libraries, and
    # pressure-vessel keeps a separate "interpreter host" stack for the
    # architecture its thunk libraries run as (its strings: the
    # "interpreter-host" provider flag, /run/interpreter-host, and the error
    # 'Graphics provider "%s" does not support %s architecture'). Declaring
    # only x86_64 left the arm64 side without a provider, so this host's mesa
    # was never wired up for it and the driver could not load — which is what
    # "failed to load driver: asahi" and the failing zink fallback
    # (VK_ERROR_INCOMPATIBLE_DRIVER, i.e. no usable ICD) both come down to.
    # x86_64.fallback_library_paths: pressure-vessel searches these "as a last
    # resort, if a library cannot be found in /etc/ld.so.cache". This matters
    # because the arm64 pressure-vessel runs without bwrap, and its ld.so.cache
    # regeneration misses the overrides dirs (the overrides symlinks into
    # /nix/store and /run/gfx only resolve after the final mount pass) — while
    # the app's LD_LIBRARY_PATH only ever contains the overrides *aliases*
    # subdirectory for the emulated architectures. Without a reachable search
    # path, Proton's `#!/usr/bin/env python3` dies with "libz.so.1: cannot
    # open shared object file" (libz is excluded from the runtime's multiarch
    # dir because the provider claims it, and its override entry lives in the
    # main overrides dir, which nothing searches).
    echo '{"graphics_provider_v0": {"architectures": {"aarch64-linux-gnu": {"flags": ["interpreter-host"]}, "x86_64-linux-gnu": {"fallback_library_paths": ["/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib/x86_64-linux-gnu", "/usr/lib64", "/lib64", "/usr/lib", "/lib"]}}}}' > /run/fex-emu/rootfs/graphics_provider.json
    # The emulated loader's cache and the x86 /bin shadow are provided by
    # the FEX rootfs OVERLAY image built in the host-side steam wrapper
    # (muvm -f base -f overlay). Deliberately NOT done with mounts here:
    # mounting a tmpfs over the rootfs /etc (the host /etc bind) stops the
    # VM from running the main command at all, and the base erofs is
    # read-only, so every write here would fail with EACCES.

    # NOTE: the dbus socket PV wants (/run/user/1000/bus) cannot be created
    # here — muvm only creates /run/user/1000 *after* this script runs, so
    # /run/user does not exist yet. The steam-fhs wrapper instead binds a
    # stub over that path inside the FHS namespace, and the guest env no
    # longer carries DBUS_SESSION_BUS_ADDRESS (see the steam wrapper).
    # (The fex-compat-tool PRESSURE_VESSEL_BWRAP patch lives in the host-side
    # steam wrapper — the guest shares the host rootfs read-only, so this
    # root script cannot edit the Steam depot.)
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
    # C++ runtime: the FEX binary (arm64, from the FEX-Emu depot) links
    # libstdc++.so.6 and libgcc_s.so.1. Without these on the FHS container's
    # library search path, FEX dies with "cannot open shared object file".
    stdenv.cc.cc.lib

    # Base libraries. pressure-vessel's container startup runs helpers from
    # this sandbox — /usr/bin/python3 lands in the container from here — while
    # resolving libraries from the runtime and the provider. The sandbox's
    # /usr/lib had none of these, so such a helper died with
    #   /usr/bin/python3: error while loading shared libraries: libz.so.1
    # (exit 127) before the launch ever reached Proton.
    zlib
    bzip2
    xz
    zstd
    expat
    libffi
    openssl
    ncurses
    readline
    sqlite
    glib
    dbus
    freetype
    fontconfig
    libpng
    alsa-lib

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

    # GPU stack paths, listed for every namespace the driver gets loaded in,
    # because they differ:
    #   * /run/opengl-driver       — the NixOS host view (client processes)
    #   * /run/host/usr/...        — pressure-vessel exposes the graphics
    #                                provider at /run/host inside the game
    #                                container, so the game's FEX host-thunk
    #                                libraries see it there
    #   * /run/fex-emu/rootfs/...  — the muvm rootfs mount itself, present in
    #                                the guest and in the FHS sandbox
    # Listing all three is deliberate: a path that doesn't resolve in the
    # current namespace is simply skipped by the loaders/warned about by PV,
    # whereas a path that resolves in none of them is what produced
    # "failed to load driver: asahi" and the zink fallback failing with
    # VK_ERROR_INCOMPATIBLE_DRIVER (no usable ICD).
    # GPU stack paths. pressure-vessel mounts the graphics provider inside the
    # game container at /run/gfx/main (its own message: '... is unlikely to
    # appear in "/run/gfx/main"'), while the host-side processes (the client,
    # and the FEX host-thunk libraries running in the guest) see the same files
    # under /nix/store and /run/opengl-driver. Both sides need to resolve, so
    # every location is listed; a path that doesn't exist in the current
    # namespace is simply skipped. This matters because mesa's DRI loader
    # stat()s <LIBGL_DRIVERS_PATH>/asahi_dri.so and reports "failed to load
    # driver: asahi" WITHOUT opening anything when the directory is absent —
    # exactly what the LD_DEBUG trace showed (no asahi_dri.so open attempt at
    # all) when only the host-side paths were listed.
    export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri:/run/gfx/main/usr/lib/aarch64-linux-gnu/dri:/run/opengl-driver/lib/dri"
    export __EGL_VENDOR_LIBRARY_DIRS="${pkgs.mesa}/share/glvnd/egl_vendor.d:/run/gfx/main/usr/share/glvnd/egl_vendor.d:/run/opengl-driver/share/glvnd/egl_vendor.d"
    export VK_ICD_FILENAMES="${pkgs.mesa}/share/vulkan/icd.d/asahi_icd.aarch64.json:/run/gfx/main/usr/share/vulkan/icd.d/asahi_icd.aarch64.json:/run/opengl-driver/share/vulkan/icd.d/asahi_icd.aarch64.json"
    export VK_DRIVER_FILES="$VK_ICD_FILENAMES"
    export LIBVA_DRIVERS_PATH="${pkgs.mesa}/lib/dri"
    export VDPAU_DRIVER_PATH=/run/opengl-driver/lib/vdpau

    # The arm64 loaders (libvulkan.so.1 / libEGL.so.1 / libGL.so.1) that the
    # FEX host-thunk libraries dlopen by name, plus libgbm for EGL — same
    # namespaces as above.
    # Base libraries are listed explicitly: helpers that pressure-vessel runs
    # in the container (e.g. the sandbox's /usr/bin/python3) resolve their
    # libraries from this variable, and the container does not inherit the
    # sandbox's own LD_LIBRARY_PATH. Without zlib there, such a helper dies
    # with "python3: error while loading shared libraries: libz.so.1"
    # (exit 127) before the launch reaches Proton.
    baseLibDirs="${pkgs.zlib}/lib:${lib.getLib pkgs.bzip2}/lib:${lib.getLib pkgs.xz}/lib:${lib.getLib pkgs.zstd}/lib:${lib.getLib pkgs.expat}/lib:${lib.getLib pkgs.libffi}/lib:${lib.getLib pkgs.openssl}/lib:${lib.getLib pkgs.ncurses}/lib:${lib.getLib pkgs.readline}/lib:${lib.getLib pkgs.sqlite}/lib:${lib.getLib pkgs.glib}/lib:${lib.getLib pkgs.dbus}/lib:${lib.getLib pkgs.freetype}/lib:${lib.getLib pkgs.fontconfig}/lib:${lib.getLib pkgs.libpng}/lib:${lib.getLib pkgs.alsa-lib}/lib"
    export LD_LIBRARY_PATH="$baseLibDirs:${lib.getLib pkgs.stdenv.cc.cc.lib}/lib:${pkgs.libgbm}/lib:${pkgs.libglvnd}/lib:${pkgs.vulkan-loader}/lib:${pkgs.mesa}/lib:/run/gfx/main/usr/lib/aarch64-linux-gnu:/run/gfx/main/usr/lib/x86_64-linux-gnu:/run/fex-emu/rootfs/usr/lib/aarch64-linux-gnu:/run/fex-emu/rootfs/usr/lib/x86_64-linux-gnu''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # --- diagnostics, opt-in: STEAM_ARM64_DEBUG=1 steam -------------------
    # PROTON_LOG always writes ~/steam-<appid>.log (wine + DXVK). The mesa and
    # loader traces are very verbose (LD_DEBUG writes one file per process),
    # so they stay off unless asked for. /home is bound into the game
    # container, so traces written under $HOME survive out of the container to
    # be read on the host.
    export PROTON_LOG=1
    export DXVK_LOG_LEVEL=info
    export LIBGL_DEBUG=verbose
    export MESA_DEBUG=1
    export LD_DEBUG=files
    export LD_DEBUG_OUTPUT="$HOME/lddbg"
    # PV's own log is kept on by default: it is the only channel that shows
    # what the game container actually receives (which libraries it captures,
    # where the graphics provider lands). One modest file per launch.
    export STEAM_LINUX_RUNTIME_LOG=1
    export STEAM_LINUX_RUNTIME_LOG_DIR="$HOME/pvlogs"

    # Graphics stack for the game container. PV's own options UI documents
    # this variable's values: "/" = "Current execution environment",
    # "/run/host" = "Host system" (only when it exists), and empty =
    # "Container's own libraries (probably won't work)" — the default, which
    # is what produced the GL failures ("kmsro: driver missing", "failed to
    # load driver: asahi") because the FEX-thunked GL calls could not reach
    # this host's arm64 mesa.
    #
    # Point it at the FEX rootfs, not "/": the provider has to satisfy the
    # x86 runtime too, and the arm64 sandbox has no x86 loader — using "/"
    # aborts with "Unable to determine provider path to
    # /lib64/ld-linux-x86-64.so.2". The rootfs is the combined-arch tree
    # (x86 loader in /lib64 plus the aarch64 mesa half), i.e. the equivalent
    # of SteamOS's /usr/share/guestos/fex-mesa that Valve's own
    # graphics_provider.json points at. It is bound into this sandbox by
    # extraBwrapArgs, so PV can read it.
    export PRESSURE_VESSEL_GRAPHICS_PROVIDER=/run/fex-emu/rootfs

    # nix-ld: on this host /lib/ld-linux-aarch64.so.1 is a symlink to
    # nix-ld, and EVERY arm64 binary in Steam's chain asks for exactly that
    # interpreter (FEXCompatTool, the FEX binary, pressure-vessel-wrap, the
    # steam-runtime-tools helpers). nix-ld then finds the real loader via
    # NIX_LD, which by default points at
    # /run/current-system/sw/share/nix-ld/lib/ld.so — a path that exists in
    # the guest but NOT inside the game container, where nix-ld aborted the
    # launch with "FATAL: panicked ... Posix(2)". Point NIX_LD at the glibc
    # store path instead: /nix/store is visible in every namespace here
    # (including inside the container), so this resolves everywhere.
    export NIX_LD=${pkgs.glibc}/lib/ld-linux-aarch64.so.1
    export NIX_LD_LIBRARY_PATH=${pkgs.glibc}/lib:/run/current-system/sw/share/nix-ld/lib

    # Rendering backend. The accelerated path runs GL/Vulkan through FEX's
    # thunks into this host's arm64 mesa, whose driver and full dependency set
    # now live inside the FEX rootfs (the provider).
    #   steam                        -> accelerated (asahi)
    #   STEAM_ARM64_SOFTWARE=1 steam -> software (llvmpipe + lavapipe)
    if [ -n "''${STEAM_ARM64_SOFTWARE:-}" ]; then
      export LIBGL_ALWAYS_SOFTWARE=1
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      export VK_ICD_FILENAMES="${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.aarch64.json"
      export VK_DRIVER_FILES="$VK_ICD_FILENAMES"
    else
      # Apple Silicon (Asahi) GPU; force the asahi driver so mesa doesn't try
      # (and fail on) radv/amdgpu and fall back to llvmpipe.
      export MESA_LOADER_DRIVER_OVERRIDE=asahi
    fi

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

    # GPU stack in this sandbox, in the same layout the FEX rootfs uses.
    # Pressure-vessel exposes the host root at /run/host inside the game
    # container, so these make /run/host/share/steam-arm64/gpu/... resolve
    # there; the client gets the same files directly. Kept out of /usr/lib
    # because the FHS builder owns that directory (creating subdirs of it
    # makes its own mkdir fail: "... : File exists").
    gpu="$out/share/steam-arm64/gpu"
    mkdir -p "$gpu/dri" "$gpu/icd.d" "$gpu/egl_vendor.d" "$gpu/lib"
    for f in ${pkgs.mesa}/lib/dri/*; do
      [ -e "$f" ] && ln -sf "$f" "$gpu/dri/"
    done
    for f in ${pkgs.mesa}/share/vulkan/icd.d/*; do
      [ -e "$f" ] && ln -sf "$f" "$gpu/icd.d/"
    done
    for f in ${pkgs.mesa}/share/glvnd/egl_vendor.d/*; do
      [ -e "$f" ] && ln -sf "$f" "$gpu/egl_vendor.d/"
    done
    for f in ${lib.getLib pkgs.libgbm}/lib/*.so*; do
      [ -e "$f" ] && ln -sf "$f" "$gpu/lib/"
    done

    # THE structural piece for GPU acceleration: an arm64 runtime inside this
    # sandbox, at /lib/aarch64-linux-gnu. The game container inherits the
    # sandbox root (PV dev-binds /) and its fallback library search includes
    # /lib/aarch64-linux-gnu and /usr/lib/aarch64-linux-gnu — but the sandbox
    # had NO arm64 libc there, so every arm64 helper inside the container
    # (PV's own /usr/bin/python3 startup step) died with
    #   libz.so.1 / libc.so.6: cannot open shared object file
    # and the launch aborted before Proton. Copy the full arm64 closure
    # (glibc, mesa+deps, loaders) from the FEX rootfs's closure.
    # /lib in the rootfs tree is a dangling symlink (lib -> /usr/lib, and
    # /usr/lib does not exist at this phase) — replace it with a real directory
    # holding the arm64 runtime.
    rm -f "$out/lib"
    mkdir -p "$out/lib/aarch64-linux-gnu"
    ${pkgs.python3}/bin/python3 ${./fex-rootfs-copy-closure.py} \
      ${steam-arm64-fex-rootfs.arm64Closure}/store-paths "$out" lib
    # The x86 side needs its own multiarch dir: it is a DEFAULT loader
    # search path inside the game container (steamrt python3 etc. run from
    # there under FEX), so libz.so.1 etc. must be present by soname.
    ${pkgs.python3}/bin/python3 ${./fex-rootfs-copy-closure.py} \
      ${steam-arm64-fex-rootfs.x86Closure}/store-paths "$out" lib
    # The client's ELF interpreter is /lib/ld-linux-aarch64.so.1 — point it at
    # the real loader inside the aarch64 tree.
    ln -sf aarch64-linux-gnu/ld-linux-aarch64.so.1 "$out/lib/ld-linux-aarch64.so.1"
    # The loader on NixOS searches /lib and /usr/lib (NOT the Debian multiarch
    # dir /lib/aarch64-linux-gnu). Expose the arm64 libs at the flat /lib level
    # so FEX's loader can resolve its NEEDED entries.
    for f in "$out"/lib/aarch64-linux-gnu/lib*.so*; do
      b=$(basename "$f")
      [ ! -e "$out/lib/$b" ] && ln -sf aarch64-linux-gnu/$b "$out/lib/$b"
    done
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
    # PV's bwrap binds the session sockets (dbus /run/user/*/bus, wayland,
    # pipewire) from its host context — which is this FHS env — and aborts
    # when the source is missing ("Can't find source path
    # /run/user/1000/bus"). Share the whole runtime dir so all session
    # sockets resolve. (uid is fixed on this host.)
    "--bind-try /run/user/1000 /run/user/1000"
    # NOTE: do NOT bind /run/opengl-driver here. Its source is a symlink in
    # the guest (muvm points it at /run/muvm-host/run/opengl-driver), and
    # bwrap then fails setting up the new root:
    #   "Can't bind mount /oldroot/nix/store/...-graphics-drivers on
    #    /newroot/run/opengl-driver: No such file or directory"
    # which aborts the whole FHS sandbox and stops the client from starting.
    # The GPU stack is reached through the FEX rootfs instead (see the
    # profile: LIBGL_DRIVERS_PATH / __EGL_VENDOR_LIBRARY_DIRS /
    # VK_ICD_FILENAMES point into /run/fex-emu/rootfs, whose aarch64 half
    # carries mesa's asahi driver, the Vulkan ICD and the EGL vendor json —
    # and that path is the one bound into every namespace).
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

    # The x86_64 side needs its own SDK symlinks. An x86 game under FEX loads
    # Proton's lsteamclient, which dlopens the native steamclient.so from
    # ~/.steam/sdk64 (or sdk32) — the directories Steam's own bootstrap
    # creates for 64/32-bit games. Only sdkarm64 exists for the arm64 client,
    # so lsteamclient found nothing and aborted the game with
    # 'steamclient_init unable to load native steamclient library' and
    # '_wassert(... steamclient_main.c, 375)' (seen as a wine assertion
    # dialog). linux64/steamclient.so is already present (fetched for FEX
    # games), so just link it.
    ln -sfn "$steam_root/linux64" "$HOME/.steam/sdk64"
    ln -sfn "$steam_root/linux32" "$HOME/.steam/sdk32"

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
      #
      # WAYLAND_DISPLAY and DBUS_SESSION_BUS_ADDRESS are deliberately NOT
      # forwarded: muvm bridges X11 and audio into the guest but neither
      # wayland nor dbus (the guest's /run/user/1000 holds only pipewire-0,
      # pulse, xauth and muvm's socat logs), so both vars pointed at sockets
      # that don't exist. PV's bwrap binds those sockets into the game
      # container and aborts when the source is missing ("Can't find source
      # path /run/user/1000/bus"), which is how the launch died. Without the
      # vars PV doesn't try to bind them. The guest reaches the host's
      # Xwayland over DISPLAY.
      env_flags=()
      for v in DISPLAY XAUTHORITY HOME \
               XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
               XDG_DATA_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME \
               PRESSURE_VESSEL_BWRAP; do
        if [ -n "''${!v:-}" ]; then
          env_flags+=(-e "$v")
        fi
      done

      # LD_LIBRARY_PATH for the muvm guest: the FEX binary (arm64, from the
      # FEX-Emu depot) needs libstdc++.so.6 and other arm64 runtime libs that
      # live in nix store paths. Without this, FEX dies with "error while
      # loading shared libraries: libstdc++.so.6".
      env_flags+=(-e "LD_LIBRARY_PATH=${lib.getLib pkgs.stdenv.cc.cc.lib}/lib:${pkgs.glibc}/lib:${pkgs.zlib}/lib")

      # The game's FEX runs inside the SLR4 pressure-vessel container, whose
      # /usr is the Steam runtime's tree — the guest-level
      # /usr/share/guestos/fex-mesa symlink is invisible there (and PV
      # refuses to bind anything under /usr). Point the compat tool's
      # STEAM_COMPAT_GRAPHICS_PROVIDER at a file inside /run/fex-emu/rootfs:
      # it derives the FEX rootfs from dirname(provider), making
      # /run/fex-emu/rootfs the RootFS everywhere, and SLR4 uses its native
      # arm64 pressure-vessel when the provider file exists.
      export STEAM_COMPAT_GRAPHICS_PROVIDER="/run/fex-emu/rootfs/graphics_provider.json"
      # /nix/store, /run/current-system and the rootfs are all bound in:
      #  * /nix/store — PV captures the provider's *drivers* (asahi_dri.so,
      #    libdril_dri.so, libgallium, the ICDs) and recreates them at their
      #    /nix/store paths inside the container, but NOT their dependencies:
      #    its own log lists no libdrm.so.2, libLLVM, libelf, libsensors,
      #    libvulkan.so.1 or libglvnd. The drivers' RPATHs point at those
      #    store paths, so the dlopen failed and mesa reported "failed to load
      #    driver: asahi". Binding the store supplies the whole dependency
      #    closure.
      #  * /run/current-system — nix-ld (the interpreter of every arm64
      #    binary in the chain, see the profile) falls back to
      #    /run/current-system/sw/share/nix-ld/lib.
      export STEAM_COMPAT_MOUNTS="/run/fex-emu/rootfs:/nix/store:/run/current-system''${STEAM_COMPAT_MOUNTS:+:$STEAM_COMPAT_MOUNTS}"

      # pressure-vessel assembles the container's /usr/lib/x86_64-linux-gnu
      # from the runtime platform MINUS every soname the graphics provider
      # claims (glibc core, libz, libstdc++, ...). Those libs are supposed to
      # come back via the overrides dir — but the emulated x86 loader never
      # searches it: LD_LIBRARY_PATH only carries the overrides *aliases*
      # subdir for x86, and the container's ld.so.cache (both PV's own
      # regeneration and the seed above) predates the point where the
      # overrides symlinks resolve. Result: Proton's `#!/usr/bin/env
      # python3` dies with "libz.so.1: cannot open shared object file".
      # Patch Proton's entry point (user-writable depot file; a Proton update
      # restores it and this re-applies at every launch) to run the
      # container's own ldconfig FIRST — inside the container, with
      # /etc/ld.so.conf already listing the overrides dirs and all mounts
      # live — and then hand over to the real Proton script.
      pdir="$HOME/.local/share/Steam/steamapps/common/Proton - Experimental"
      if [ -f "$pdir/proton.real-backup" ] && [ ! -f "$pdir/proton.real" ]; then
        mv "$pdir/proton.real-backup" "$pdir/proton.real"
      fi
      if [ -f "$pdir/proton" ] && [ "$(head -1 "$pdir/proton" 2>/dev/null)" = '#!/usr/bin/env python3' ]; then
        mv "$pdir/proton" "$pdir/proton.real"
      fi
      if [ -f "$pdir/proton.real" ] && ! grep -q PROTON_LDWRAPPER "$pdir/proton" 2>/dev/null; then
        cat > "$pdir/proton" <<'PHEOF'
#!/bin/sh
# PROTON_LDWRAPPER: regenerate the container loader cache (the shipped one
# is stale — see the steam-arm64 wrapper), then run the real Proton script.
{
  echo "=== PROTON_LDWRAPPER $(date) ==="
  /sbin/ldconfig 2>&1 || /usr/sbin/ldconfig 2>&1 || true
  echo "ldconfig rc=$?"
  echo "cache bytes: $(wc -c < /etc/ld.so.cache 2>&1)"
  tr -c '[:print:]' '\n' < /etc/ld.so.cache 2>/dev/null | grep -c pressure-vessel
} >> "$HOME/proton-ldwrapper.log" 2>&1
exec "$(dirname "$0")/proton.real" "$@"
PHEOF
        chmod +x "$pdir/proton"
      fi

      # The SAME loader-search gap hits pressure-vessel's own in-container
      # call of /usr/bin/python3 (it verifies the runtime before the app
      # runs): python3 needs libz.so.1, which the provider claims and the
      # container therefore lacks at its multiarch path. Wrap the platform's
      # python3.13 (user-writable depot file; a Steam runtime update restores
      # it and this re-applies at every launch) to add the overrides main
      # dir — bound into the container and fully resolvable there — to
      # LD_LIBRARY_PATH for python only.
      # pressure-vessel's non-bwrap container setup points the emulated x86
      # loader's /etc/ld.so.cache through a symlink chain ending at
      # etc/runtime-ld.so.cache in the runtime sysroot — a file the SLR4
      # platform does not ship. The dangling chain leaves every emulated
      # process in the container without a loader cache, so each setup
      # binary (mkdir, ...) only resolves through LD_LIBRARY_PATH and the
      # nix-style default path. Ship the platform's own cache under the
      # expected name (user-writable depot file; re-applied per launch).
      for d in "$HOME"/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/steamrt4_platform_*/files; do
        [ -d "$d/etc" ] || continue
        if [ ! -f "$d/etc/runtime-ld.so.cache" ] && [ -f "$d/etc/ld.so.cache" ]; then
          cp -f "$d/etc/ld.so.cache" "$d/etc/runtime-ld.so.cache" 2>/dev/null || true
        fi
        break
      done

      for plat in "$HOME"/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/steamrt4_platform_*/files; do
        [ -d "$plat/bin" ] || continue
        # Recover from the previous iteration of this patch (relative exec
        # path) before deciding anything.
        if grep -q PYTHON_LDWRAPPER "$plat/bin/python3.13" 2>/dev/null &&
           [ -f "$plat/bin/python3.13.real" ]; then
          :  # wrapper already in place; refresh pydoc copy below
        elif [ "$(wc -c < "$plat/bin/python3.13" 2>/dev/null || echo 0)" -gt 100000 ]; then
          mv "$plat/bin/python3.13" "$plat/bin/python3.13.real"
        fi
        [ -f "$plat/bin/python3.13.real" ] || continue
        # The container /usr/bin is populated from the runtime manifest, so
        # unlisted files (python3.13.real) never appear there. Park the real
        # ELF under pydoc3.13, which IS in the manifest and is reachable
        # in-container at /usr/bin/pydoc3.13.
        cp -f "$plat/bin/python3.13.real" "$plat/bin/pydoc3.13"
        printf '%s\n' \
          '#!/bin/sh' \
          '# PYTHON_LDWRAPPER: give python the overrides dir that the' \
          '# container loader cannot reach otherwise (see steam-arm64 wrapper).' \
          'export LD_LIBRARY_PATH="/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' \
          'exec /usr/bin/pydoc3.13 "$@"' > "$plat/bin/python3.13"
        chmod +x "$plat/bin/python3.13" "$plat/bin/pydoc3.13"
        break
      done

      # ── FEX rootfs overlay (second -f image) ───────────────────────────
      # Supplies what the base erofs cannot: the x86 /bin shadow (Valve's
      # scripts need an x86 /bin/sh under the rootfs) and the emulated
      # side's ld.so.cache. Mounts cannot do this job: the rootfs /etc is
      # the host /etc bind (mounting a tmpfs over it stops the VM from
      # running the main command at all), /var is a root-only host bind, and
      # muvm only tolerates a single tmpfs mount below the FEX rootfs.
      # muvm's own overlay-image mechanism (-f base -f overlay, later images
      # take precedence) is the supported way.
      ovl_dir="$(mktemp -d)"
      mkdir -p "$ovl_dir/bin" "$ovl_dir/etc" "$ovl_dir/var/cache/ldconfig"
      ln -s ${pkgsCross.gnu64.bash}/bin/bash "$ovl_dir/bin/bash"
      ln -s bash "$ovl_dir/bin/sh"
      ln -s ${pkgsCross.gnu64.coreutils}/bin/env "$ovl_dir/bin/env"
      for plat in "$HOME"/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/steamrt4_platform_*/files; do
        [ -d "$plat" ] || continue
        # The runtime's own x86 libraries. FEX redirects every emulated
        # library open through its rootfs, so the rootfs view of
        # /usr/lib/x86_64-linux-gnu must contain the union of the provider
        # set (base erofs) and these — otherwise the container's setup
        # binaries (mkdir, ...) fail on libraries that only the runtime
        # ships, e.g. "mkdir: libselinux.so.1: cannot open shared object
        # file". Symlinks into the (home) depot are valid both in the guest
        # and inside the game container.
        mkdir -p "$ovl_dir/usr/lib/x86_64-linux-gnu"
        for f in "$plat"/lib/x86_64-linux-gnu/*; do
          [ -f "$f" ] || continue
          ln -sf "$f" "$ovl_dir/usr/lib/x86_64-linux-gnu/$(basename "$f")"
        done
        [ -r "$plat/etc/ld.so.cache" ] || break
        cp "$plat/etc/ld.so.cache" "$ovl_dir/etc/ld.so.cache"
        cp "$plat/etc/ld.so.cache" "$ovl_dir/etc/runtime-ld.so.cache"
        cp "$plat/etc/ld.so.cache" "$ovl_dir/var/cache/ldconfig/ld.so.cache"
        break
      done
      chmod 755 "$ovl_dir" "$ovl_dir/bin" "$ovl_dir/etc" "$ovl_dir/var" \
                "$ovl_dir/var/cache" "$ovl_dir/var/cache/ldconfig" 2>/dev/null || true
      chmod 644 "$ovl_dir"/etc/*.cache "$ovl_dir"/var/cache/ldconfig/*.cache 2>/dev/null || true
      ovl_image="$(mktemp --suffix=.erofs)"
      ${pkgs.erofs-utils}/bin/mkfs.erofs -zlz4 "$ovl_image" "$ovl_dir" || true

      XDG_RUNTIME_DIR="$iso_runtime" \
        exec ${muvm}/bin/muvm "''${env_flags[@]}" \
          -e "XDG_RUNTIME_DIR=$real_runtime" \
          -e "STEAM_COMPAT_MOUNTS=$STEAM_COMPAT_MOUNTS" \
          -e "STEAM_COMPAT_GRAPHICS_PROVIDER=$STEAM_COMPAT_GRAPHICS_PROVIDER" \
          -f ${steam-arm64-fex-rootfs} \
          -f "$ovl_image" \
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
