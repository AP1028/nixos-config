{
  config,
  lib,
  pkgs,
  ...
}: let
  # ── Helper derivations ──────────────────────────────────────────

  # Cadence's liblog4cxx (IC25.1) needs libapr-1.so.0. nixpkgs' apr has an
  # IFUNC relocation for `modf` (from libm) that crashes inside glibc 2.42's
  # eager-relocation path because libapr doesn't list libm in NEEDED.
  # Adding libm.so.6 to NEEDED fixes the crash (no LD_PRELOAD required —
  # Cadence's saSecurity rejects preloads).
  cds-apr = pkg: pkgs.stdenv.mkDerivation {
    pname = "cds-apr-libm";
    version = pkg.version;
    src = pkg;
    nativeBuildInputs = [pkgs.patchelf];
    unpackPhase = "true";
    buildPhase = ''
      mkdir -p $out/lib
      cp -a $src/lib/libapr-1.so.0* $out/lib/
      chmod +w $out/lib/libapr-1.so.0.*
      patchelf --add-needed libm.so.6 $out/lib/libapr-1.so.0.*
    '';
    installPhase = "true";
  };

  # aarch64 hosts (macbook): Cadence tools are x86_64 binaries, so the FHS env
  # carries box64 + an x86_64 library tree and cadence entry points are
  # wrapped in box64 launchers. x86_64 hosts run the tools natively.
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;

  x86 = pkgs.pkgsCross.gnu64;

  # x86_64 counterparts of the libraries the Cadence tools need (subset;
  # extend after checking `readelf -d` / ldd of the actual install).
  x86LibPkgs = [
    x86.glibc
    x86.zlib
    x86.zstd
    x86.pcre2
    x86.nss
    x86.nspr
    x86.gcc-unwrapped.lib
    x86.openssl
    x86.expat
    x86.ncurses
    x86.sqlite
    x86.libffi
    x86.readline
    x86.bzip2
    x86.xz
    x86.krb5.lib
    x86.e2fsprogs.out
    x86.alsa-lib
    x86.libusb1
    x86.dbus
    x86.cyrus_sasl
    x86.openldap
    x86.file
    x86.libpciaccess
    (cds-apr x86.apr)
    x86.aprutil
    x86.libX11
    x86.libXext
    x86.libXrender
    x86.libXtst
    x86.libXi
    x86.libXrandr
    x86.libXcursor
    x86.libXcomposite
    x86.libXdamage
    x86.libXfixes
    x86.libXp
    x86.libXau
    x86.libXdmcp
    x86.libXScrnSaver
    x86.libxcb
    x86.libxshmfence
    x86.libICE
    x86.libSM
    x86.libXmu
    x86.libXt
    x86.libXft
    x86.libXinerama
    x86.libXaw
    x86.fontconfig
    x86.freetype
    x86.libGLU
    x86.libglvnd
    x86.motif
    x86.libpng
    x86.libjpeg
    x86.libxml2
    x86.elfutils.out # default output is "bin" (no lib) — use "out"
    x86.glib
    x86.pango
    x86.gtk2
    x86.gtk3
  ];

  # box64 launchers for the Cadence entry points (aarch64 hosts only). They
  # resolve the real binaries relative to $CDSBASE, which the profile sets.
  cadence-box64-bins = pkgs.runCommand "cadence-box64-bin" {} ''
    mkdir -p $out/bin
    make_launcher() {
      cat > $out/bin/$1 <<EOF
    #!/bin/sh
    exec ${pkgs.box64}/bin/box64 "\$CDSBASE/$2" "\$@"
    EOF
      chmod +x $out/bin/$1
    }
    make_launcher virtuoso "IC251/tools/dfII/bin/virtuoso"
    make_launcher spectre "spectre181/bin/spectre"
  '';

  # ── FEX (muvm) aarch64 runtime ─────────────────────────────────
  #
  # FEX needs a 4K-page kernel, but this host runs a 16K-page kernel, so FEX
  # runs inside a muvm microVM (whose guest kernel uses 4K pages). muvm's
  # guest registers a FEX binfmt handler and mounts the erofs rootfs below at
  # /run/fex-emu/rootfs; x86_64 ELFs exec through FEX transparently.

  # Extra x86_64 libs the real virtuoso binary links that are not already in
  # x86LibPkgs (lapack/blas/gfortran for the numeric kernels).
  fexExtraX86LibPkgs = [
    x86.openblas
    x86.gfortran.cc.lib
    x86.libxcrypt-legacy
    x86.libnsl
    x86.libuuid
    x86.libelf
    x86.systemd
    x86.libxkbcommon
    x86.xcbutilwm
    x86.xcbutilimage
    x86.xcbutilkeysyms
    x86.xcbutilrenderutil
    x86.pciutils
    x86.libidn2
    x86.libssh
    x86.xcbutil
  ];

  # erofs image of the x86_64 userspace Cadence needs. The SuSE-built Cadence
  # binaries use a standard /lib64/ld-linux-x86-64.so.2 interpreter and expect
  # system libs under /usr/lib64; the rootfs provides those as symlinks into
  # the shared nix store (visible through the muvm guest), plus the aarch64
  # shells the Cadence ksh/tcsh launcher scripts are written in.
  fex-cadence-rootfs = pkgs.runCommand "fex-cadence-rootfs" {
    nativeBuildInputs = [pkgs.erofs-utils];
  } ''
    mkdir -p rootfs/lib64 rootfs/usr/lib64 rootfs/bin
    ln -sf ${x86.glibc}/lib/ld-linux-x86-64.so.2 rootfs/lib64/ld-linux-x86-64.so.2
    for p in ${lib.concatMapStringsSep " " (p: "${lib.getLib p}") (x86LibPkgs ++ fexExtraX86LibPkgs)}; do
      if [ -d "$p/lib" ]; then
        for f in "$p"/lib/*; do
          [ -e "$f" ] || continue
          case "$f" in
            *.a|*.la|*.o|*gconv*) continue ;;
          esac
          ln -sf "$f" rootfs/usr/lib64/
        done
      fi
    done
    # aarch64 shells for the guest (Cadence launchers are ksh/tcsh scripts)
    ln -sf ${pkgs.ksh}/bin/ksh rootfs/bin/ksh
    ln -sf ${pkgs.tcsh}/bin/tcsh rootfs/bin/tcsh
    ln -sf ${pkgs.bash}/bin/bash rootfs/bin/bash
    ln -sf bash rootfs/bin/sh
    # Cadence SLES12-era SONAME compat symlinks (mirrors the box64 FHS env)
    ln -sf libldap.so.2 rootfs/usr/lib64/libldap_r-2.4.so.2
    ln -sf liblber.so.2 rootfs/usr/lib64/liblber-2.4.so.2
    ln -sf libapr-1.so.0.7.6 rootfs/usr/lib64/libapr-1.so.0.5.1
    # saSecurity parses /proc/self/maps and requires the libc mapping to live
    # under /usr/lib64/libc-* (nix-store paths are treated as tampering). A
    # symlink resolves to the store path in maps, so copy the real glibc
    # libc.so.6 over it; LD_LIBRARY_PATH starts with /usr/lib64 so the loader
    # opens it there and the kernel records /usr/lib64/libc.so.6.
    rm -f rootfs/usr/lib64/libc.so.6
    cp ${x86.glibc}/lib/libc.so.6 rootfs/usr/lib64/libc.so.6
    chmod 755 rootfs/usr/lib64/libc.so.6
    mkfs.erofs $out rootfs/
  '';

  # Guest-side script: sets the Cadence environment then execs tcsh (so
  # `cadence-env -c '...'` behaves exactly like the FHS-env version).
  cadence-env-guest = pkgs.writeShellScript "cadence-env-guest" ''
    export IN_FHS_ENV="cadence-env"
    unset http_proxy https_proxy ftp_proxy rsync_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY RSYNC_PROXY ALL_PROXY no_proxy NO_PROXY
    export LANG=C LC_ALL=C
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    # HiDPI: the guest X server (host Xwayland) reports 96 DPI on the 2560x1600
    # physical display, so Qt renders at 1x and the UI is tiny. Scale it up.
    # (aarch64/FEX guest only; the x86_64 native path is unaffected.)
    # 1.3 is the sweet spot here (2 was too large, 1.5 still too large); tune if needed.
    export QT_ENABLE_HIGHDPI_SCALING=1
    export QT_SCALE_FACTOR=1.3
    export QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough
    # saSecurity requires the licensing-agent mode disabled and the VSM
    # framework vars set before it will attempt the license checkout.
    export CDS_LIC_USE_AGENT=0
    export VSM_FWK=VSM95011
    export VSM_ITK=VSM12141
    # The x86_64 ld-linux (nixpkgs glibc) only searches its own store lib dir
    # by default; point it at the rootfs system libs.
    export LD_LIBRARY_PATH="/usr/lib64:/lib64''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # EE477 environment (equivalent of sourcing setup_ee477_ee577a_v2602.csh)
    export CDSBASE="$HOME/.cadence"
    export CDS_INST_DIR="$CDSBASE/IC251"
    export IC_HOME="$CDS_INST_DIR"
    export CDSHOME="$CDS_INST_DIR"
    export OA_HOME="$CDS_INST_DIR/share/oa"
    # The OA libs are the x86_64 build (share/oa/lib/linux_rhel80_64), but the
    # launcher scripts run natively (aarch64) so `uname -m` reports aarch64 and
    # oaGetLibPath/sysname pick the aarch64 OA platform "lna64_rhel80" instead.
    # Pin the OA platform name to the x86_64 one.
    export OA_SYSNAME=linux_rhel80
    export CDS_AUTO_64BIT=ALL
    export CDS_Netlisting_Mode=Analog
    # NOTE: SPECTRE_DEFAULTS=-E is deliberately NOT set here. Together with
    # CDS_Netlisting_Mode=Analog it makes virtuoso spin ~120s in "Virtuoso
    # initialization" probing the (missing) AMS library on this install. The
    # AMS Unified netlister is unusable here anyway (AMS-2910), so dropping the
    # Spectre default just avoids the slow probe.
    # asusg16 .cshrc sets these too; keep the license + platform vars in sync
    export CDS_LIC_FILE="$CDSBASE/license/license.dat"
    export CDS_LIC_ONLY=1
    export W3264_NO_HOST_CHECK=1
    export OA_UNSUPPORTED_PLAT=linux_rhel80
    export CDS_ENABLE_VMS=1
    export CDS_LOAD_ENV=CWD
    for p in "$IC_HOME/bin" "$IC_HOME/tools/bin" "$IC_HOME/tools/dfII/bin"; do
      case ":$PATH:" in
        *":$p:"*) ;;
        *) PATH="$p:$PATH" ;;
      esac
    done
    # user wrapper dir first: ~/.cadence/bin/virtuoso preloads the PDK libs
    export PATH="$HOME/.cadence/bin:$PATH"
    export PATH
    exec ${pkgs.tcsh}/bin/tcsh "$@"
  '';

  # Guest-side root setup script (run via muvm `-x` before the user command).
  # Cadence's ksh/tcsh launcher scripts (libManager, libSelect, cdsPstack, ...)
  # have `#!/bin/ksh`/`#!/bin/tcsh` shebangs and call common POSIX tools, but
  # the VM's /bin only has `sh -> bash` (it mirrors the host NixOS /bin). Mount
  # a tmpfs over /bin and link in the aarch64 shells + tools the launchers need.
  cadence-env-guest-bin = pkgs.writeShellScript "cadence-env-guest-bin" ''
    mount -t tmpfs tmpfs /bin
    mount -t tmpfs tmpfs /usr/bin

    for tool in ${pkgs.coreutils}/bin/*; do
      [ -e "$tool" ] && ln -s "$tool" /bin/ 2>/dev/null
      [ -e "$tool" ] && ln -s "$tool" /usr/bin/ 2>/dev/null
    done
    for tool in ${pkgs.gnused}/bin/* ${pkgs.gawk}/bin/* ${pkgs.gnugrep}/bin/* ${pkgs.procps}/bin/* ${pkgs.strace}/bin/* ${pkgs.gdb}/bin/*; do
      [ -e "$tool" ] && ln -s "$tool" /bin/ 2>/dev/null
      [ -e "$tool" ] && ln -s "$tool" /usr/bin/ 2>/dev/null
    done

    # Replace `uname` with a wrapper that reports x86_64 for `-m`. cds_plat /
    # cds_root spawn `/bin/uname -m` (a native aarch64 binary) to detect the
    # host platform; the real "aarch64" answer makes them report "lna64" and
    # virtuoso treats the run as "cross platform" ("lnx86" on "lna64"), which
    # makes it retry for ~120s in "Virtuoso initialization". Everything else
    # (the OS name etc.) is identical between the two arches.
    rm -f /bin/uname /usr/bin/uname
    cat > /bin/uname <<UN
    #!/bin/sh
    if [ "\$1" = "-m" ]; then
      echo x86_64
    else
      exec ${pkgs.coreutils}/bin/uname "\$@"
    fi
    UN
    chmod +x /bin/uname
    ln -sf /bin/uname /usr/bin/uname

    ln -s ${pkgs.ksh}/bin/ksh /bin/ksh
    ln -s ${pkgs.tcsh}/bin/tcsh /bin/tcsh
    ln -s ${pkgs.bash}/bin/bash /bin/bash
    ln -s ${pkgs.bash}/bin/bash /bin/sh
    ln -s ${pkgs.ksh}/bin/ksh /usr/bin/ksh
    ln -s ${pkgs.tcsh}/bin/tcsh /usr/bin/tcsh
    ln -s ${pkgs.bash}/bin/bash /usr/bin/bash
    ln -s ${pkgs.hostname}/bin/hostname /bin/hostname
    ln -s ${pkgs.hostname}/bin/hostname /usr/bin/hostname
    ln -s ${pkgs.hostname}/bin/hostname /bin/domainname
    ln -s ${pkgs.hostname}/bin/hostname /usr/bin/domainname
  '';

  # ── FHS environment ─────────────────────────────────────────────

  cadence-env-raw = pkgs.buildFHSEnv {
    name = "cadence-env";
    targetPkgs = pkgs: (with pkgs; [
      glibc
      zlib
      zstd
      systemd
      pcre2
      nss
      nspr
      gcc-unwrapped.lib
      stdenv.cc.cc.lib
      bash
      tcsh
      ksh
      coreutils
      procps
      xvfb
      gawk
      perl
      python3
      libX11
      libXext
      libXrender
      libXtst
      libXi
      libXrandr
      libXcursor
      libXScrnSaver
      libXcomposite
      libXdamage
      libXfixes
      libxcb
      libxshmfence
      libpciaccess
      pciutils
      libusb1
      motif
      fontconfig
      freetype
      libGLU
      libglvnd
      glib
      pango
      gtk2
      gtk3
      alsa-lib
      xwayland
      nettools
      iproute2
      libnsl
      ncurses5
      libxcrypt-legacy
      expat
      libpng
      libjpeg
      krb5
      e2fsprogs
      libICE
      libSM
      libXmu
      libXt
      libelf
      elfutils
      libpng12
      libXft
      libXinerama
      libuuid
      qt5.qtx11extras
      qt5.qtbase
      libxkbcommon
      dbus
      xcbutilwm
      xcbutilimage
      xcbutilkeysyms
      xcbutilrenderutil
      libxml2
      libXaw
      libtool
      xdpyinfo
      mesa-demos
      openjdk11
      libidn2
      libssh
      apr
      aprutil
      cyrus_sasl
      openldap
      file
      sqlite
      xkeyboard_config # Provides the layout data for XKB
      lsb-release
    ] ++ lib.optionals isAarch64 [
      box64
      cadence-box64-bins
      # box64 wraps these heavy libs NATIVELY (ARM64) when present; the x86_64
      # virtuoso links them, so supply the aarch64 versions in the env.
      openssl # libcrypto.so.3
      openblas # libblas.so / liblapack.so
      lapack
    ]);
    multiPkgs = pkgs: (with pkgs; [
      libxml2
      zlib
      glibc
      libglvnd
      gcc-unwrapped.lib
      libXext
      libX11
      libXtst
      libXi
      libXp
      libpciaccess
      sqlite
    ]);

    extraBuildCommands = ''
      # Cadence's saSecurity parses /proc/self/maps and requires the libc
      # mapping to live under /usr/lib64/libc-* or /lib64/libc-* (nix-store
      # paths are treated as tampering). Place a real libc file at the
      # standard path so the kernel records /usr/lib64/libc.so.6 in the maps.
      rm -f $out/usr/lib64/libc.so.6
      cp ${pkgs.glibc.out}/lib/libc.so.6 $out/usr/lib64/libc.so.6
      chmod 755 $out/usr/lib64/libc.so.6
      mkdir -p $out/usr/lib64
      # patched apr under the name Cadence's SuSE/SLES12 symlink expects
      ln -sf ${cds-apr pkgs.apr}/lib/libapr-1.so.0.7.6 $out/usr/lib64/libapr-1.so.0.5.1
      ln -sf ${cds-apr pkgs.apr}/lib/libapr-1.so.0.7.6 $out/usr/lib64/libapr-1.so.0
      # old-SONAME OpenLDAP compat for Cadence's liblog4cxx
      ln -sf ${pkgs.openldap}/lib/libldap.so.2 $out/usr/lib64/libldap_r-2.4.so.2
      ln -sf ${pkgs.openldap}/lib/liblber.so.2 $out/usr/lib64/liblber-2.4.so.2
    '' + lib.optionalString isAarch64 ''
      # x86_64 multiarch lib tree for box64 (Cadence tools are x86_64).
      # NOTE: $out/lib is a usrmerge symlink (-> /usr/lib -> /usr/lib64 on
      # aarch64), so create the tree under the real directory.
      mkdir -p $out/usr/lib64/x86_64-linux-gnu
      for d in ${lib.concatMapStringsSep " " (p: "${p}/lib") x86LibPkgs}; do
        if [ -d "$d" ]; then
          cp -a "$d"/. $out/usr/lib64/x86_64-linux-gnu/
          # cp -a preserves the source dir's (read-only) mode onto the
          # destination dir; restore write permission for the next copy.
          chmod -R u+w $out/usr/lib64/x86_64-linux-gnu
        fi
      done

      # box64 0.4.2 wraps ANY lib with an ARM64 twin in the env natively, and
      # native-wrapped libs cannot provide DATA symbols (widget class records,
      # _XtInheritTranslations, ...) to emulated code — the emulated Motif/Xm
      # stack needs those. Remove the ARM64 X/UI libs so box64 falls back to
      # emulating the x86_64 versions from the multiarch tree. (Nix-store
      # binaries like Xvfb don't use /usr/lib64, so they are unaffected.)
      rm -f $out/usr/lib64/libX11.so* $out/usr/lib64/libX11-xcb.so* \
            $out/usr/lib64/libXau.so* $out/usr/lib64/libxcb.so* \
            $out/usr/lib64/libXdmcp.so* $out/usr/lib64/libXext.so* \
            $out/usr/lib64/libXft.so* $out/usr/lib64/libXmu.so* \
            $out/usr/lib64/libXrender.so* $out/usr/lib64/libXss.so* \
            $out/usr/lib64/libXt.so* $out/usr/lib64/libXtst.so* \
            $out/usr/lib64/libXi.so* $out/usr/lib64/libXrandr.so* \
            $out/usr/lib64/libXcursor.so* $out/usr/lib64/libXcomposite.so* \
            $out/usr/lib64/libXdamage.so* $out/usr/lib64/libXfixes.so* \
            $out/usr/lib64/libXScrnSaver.so* $out/usr/lib64/libXp.so* \
            $out/usr/lib64/libXinerama.so* $out/usr/lib64/libXaw.so* \
            $out/usr/lib64/libXm.so* $out/usr/lib64/libxkbcommon.so* \
            $out/usr/lib64/libxcb-*.so* 2>/dev/null || true
    '';

    profile = ''
      export XKB_CONFIG_ROOT=/usr/share/X11/xkb
      export IN_FHS_ENV="cadence-env"
      unset http_proxy https_proxy ftp_proxy rsync_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY RSYNC_PROXY ALL_PROXY no_proxy NO_PROXY
      export LANG=C LC_ALL=C
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri"
      if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
        export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
        export __GLX_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/glx_vendor.d"
      fi
      export XLIB_SKIP_ARGB_VISUALS="1"
      # HiDPI: the Cadence tools are X11 apps shown through Xwayland; scale the
      # Qt UI by 1.2 (the asusg16 panel DPI) instead of the default 1x.
      export QT_ENABLE_HIGHDPI_SCALING=1
      export QT_SCALE_FACTOR=1.2
      export QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough
      # saSecurity requires the licensing-agent mode disabled and the VSM
      # framework vars set before it will attempt the license checkout.
      export CDS_LIC_USE_AGENT=0
      export VSM_FWK=VSM95011
      export VSM_ITK=VSM12141
      export LD_LIBRARY_PATH="/usr/lib64:/usr/lib:/run/opengl-driver/lib:/run/opengl-driver-32/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      ${lib.optionalString isAarch64 ''
        # x86_64 Cadence tools run under box64; point it at the multiarch tree.
        export BOX64_LD_LIBRARY_PATH="/lib/x86_64-linux-gnu''${BOX64_LD_LIBRARY_PATH:+:$BOX64_LD_LIBRARY_PATH}"
        export BOX64_LOG=0
        # box64 natively wraps X/GL libs when ARM64 versions are reachable
        # (they are, via /usr/lib64), but native-wrapped libs cannot provide
        # DATA symbols (widget class records, _XtInheritTranslations, ...) to
        # emulated code — the emulated Motif/Xm stack needs those. Keep only
        # the core runtime + heavy math/crypto libs wrapped; everything else
        # (X11/Xt/Motif/GL) is emulated from the x86_64 tree.
        export BOX64_WRAPPED_LIBS="libc.so.6:libm.so.6:libdl.so.2:libpthread.so.0:librt.so.1:libutil.so.1:libgcc_s.so.1:libstdc++.so.6:libcrypto.so.3:libopenblas.so:liblapack.so.3"
      ''}
      # EE477 environment (equivalent of sourcing setup_ee477_ee577a_v2602.csh)
      export CDSBASE="$HOME/.cadence"
      export CDS_INST_DIR="$CDSBASE/IC251"
      export IC_HOME="$CDS_INST_DIR"
      export CDSHOME="$CDS_INST_DIR"
      export SPECTRE_HOME="$CDSBASE/spectre181"
    export OA_HOME="$CDS_INST_DIR/share/oa"
    # The OA libs are the x86_64 build (share/oa/lib/linux_rhel80_64), but the
    # launcher scripts run natively (aarch64) so `uname -m` reports aarch64 and
    # oaGetLibPath/sysname pick the aarch64 OA platform "lna64_rhel80" instead.
    # Pin the OA platform name to the x86_64 one.
    export OA_SYSNAME=linux_rhel80
      export CDS_AUTO_64BIT=ALL
      export CDS_Netlisting_Mode=Analog
      export SPECTRE_DEFAULTS=-E
    for p in "$SPECTRE_HOME/bin" "$IC_HOME/bin" "$IC_HOME/tools/bin" "$IC_HOME/tools/dfII/bin"; do
        case ":$PATH:" in
          *":$p:"*) ;;
          *) PATH="$p:$PATH" ;;
        esac
      done
      # user wrapper dir first: ~/.cadence/bin/virtuoso preloads the PDK libs
      export PATH="$HOME/.cadence/bin:$PATH"
      export PATH
    '';
    runScript = "tcsh";
  };

  # ── Wrapper ─────────────────────────────────────────────────────

  # Background poller that reads the compositor's CPU once a second. This is a
  # deliberate timing perturbation: closing a window can hang the compositor
  # (an Xwayland damage-extension race — see docs/cadence-fex.md "UNRESOLVED"),
  # and a per-second fork/exec of `ps` against kwin changes the scheduling
  # enough that the close minimizes instead of hanging. Mirrors the watchdog
  # used to diagnose the bug. One poller per cadence-env session is negligible.
  poller = ''
    # Poll once synchronously so the timing perturbation is established before
    # the env (muvm / FHS env) actually launches, then keep polling once a
    # second in the background.
    poll_once() {
      KPID=$(pgrep -f "kwin_wayland --wayland-fd" | head -1)
      [ -n "$KPID" ] && ps -o pcpu= -p "$KPID" >/dev/null 2>&1
    }
    poll_once
    ( while :; do poll_once; sleep 1; done ) &
    poller_pid=$!
    trap 'kill $poller_pid 2>/dev/null' EXIT
  '';

  # x86_64 hosts: run as the main user in the no-internet group (license
  # daemon / firewall isolation). aarch64 hosts: run inside the muvm microVM
  # under FEX (the 16K-page host kernel cannot run FEX directly).
  cadence-env =
    if isAarch64
    then
      pkgs.writeShellScriptBin "cadence-env" ''
        # Nuke a lingering previous session before starting a fresh VM. muvm is
        # single-instanced here, and a prior run's guest VM can fail to shut down
        # (the dashboard daemon holds the session lock), leaving muvm + its sudo
        # parent + the wrapper + poller behind. Kill them all (never this shell).
        pkill -9 -f "${pkgs.muvm}/bin/muvm" 2>/dev/null
        for pid in $(pgrep -f "/bin/cadence-env" 2>/dev/null); do
          [ "$pid" = "$$" ] && continue
          kill -9 "$pid" 2>/dev/null
        done
        sleep 1
        ${poller}
        # Run muvm in the no-internet group (like the x86_64 path), so passt —
        # which muvm spawns for the VM's networking — inherits the group and the
        # host iptables `-m owner --gid-owner no-internet` REJECT rule makes any
        # guest outbound connection fail fast instead of hanging on timeouts.
        /run/wrappers/bin/sudo -E -u ${config.local.username} -g no-internet ${pkgs.muvm}/bin/muvm \
          -f ${fex-cadence-rootfs} \
          -m \
          -x ${cadence-env-guest-bin} \
          -e DISPLAY \
          -e XAUTHORITY \
          -- ${cadence-env-guest} "$@"
      ''
    else
      pkgs.writeShellScriptBin "cadence-env" ''
        ${poller}
        /run/wrappers/bin/sudo -E -u ${config.local.username} -g no-internet ${cadence-env-raw}/bin/cadence-env "$@"
      '';
in {
  environment.systemPackages = [cadence-env];

  # Cadence's ksh/tcsh launcher scripts probe `[ -r /lib64/. ]` (and some check
  # /usr/lib64) to decide 32-vs-64-bit. NixOS is not usr-merged, so neither
  # exists; the muvm guest mirrors the host / via virtiofs (read-only for the
  # mapped user), so these must be created on the host. The empty dirs make the
  # "64-bit host" check pass (the real x86_64 libs come from the FEX rootfs).
  systemd.tmpfiles.rules = lib.mkIf isAarch64 [
    "d /lib64 0755 root root -"
    "d /usr/lib64 0755 root root -"
  ];

  # Allow passwordless sudo for the cadence-env wrapper (needed for the
  # no-internet group switch). On aarch64 it runs muvm, on x86_64 the FHS env.
  security.sudo.extraRules = [
    {
      users = [config.local.username];
      runAs = "ALL";
      commands = [
        {
          command =
            if isAarch64
            then "${pkgs.muvm}/bin/muvm"
            else "${cadence-env-raw}/bin/cadence-env";
          options = ["NOPASSWD" "SETENV"];
        }
      ];
    }
  ];
}
