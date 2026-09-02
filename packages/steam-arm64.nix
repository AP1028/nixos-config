{
  lib,
  stdenv,
  fetchurl,
  buildFHSEnv,
  writeShellScript,
  writeShellScriptBin,
  symlinkJoin,
  python3,
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
  # x86-only glibc_multi.bin).
  targetPkgs = pkgs: with pkgs; [
    bash
    coreutils
    file
    lsb-release
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
    libxcb
    libxinerama
    libsm
    libice

    fontconfig
    freetype

    glib
    gtk2
    gdk-pixbuf

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
  '';

  extraInstallCommands = ''
    ln -s ${steam-arm64-unwrapped}/share "$out/share"
  '';

  extraBwrapArgs = [
    "--bind-try /tmp/dumps /tmp/dumps"
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

    # ~/.steam symlinks point Steam at its install/data root.
    mkdir -p "$HOME/.steam"
    ln -sfn "$steam_root" "$HOME/.steam/steam"
    ln -sfn "$steam_root" "$HOME/.steam/root"

    # Run the native client directly. Its updater exits with code 42
    # (MAGIC_RESTART) after installing an update, so honour that by
    # re-launching with the freshly-installed client.
    while true; do
      "$client_dir/steam" "$@" 2> "$HOME/steam_client_stderr.log"
      status=$?
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

      XDG_RUNTIME_DIR="$iso_runtime" \
        exec ${muvm}/bin/muvm "''${env_flags[@]}" \
          -e "XDG_RUNTIME_DIR=$real_runtime" \
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
