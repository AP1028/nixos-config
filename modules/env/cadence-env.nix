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
    make_launcher spectre "spectre251/bin/spectre"
    # direct-ELF launcher: skips the ksh wrapper entirely — box64 runs the
    # x86_64 engine with the bundled private libs on its search path
    cat > $out/bin/spectre64 <<EOF
    #!/bin/sh
    T="\$CDSBASE/spectre251/tools.lnx86"
    BOX64_LD_LIBRARY_PATH="\$T/lib/64bit:\$T/inca/lib/64bit:\$T/spectre/lib/64bit:\$T/tcltk-8.6.8/lib/64bit:\$T/mdl/lib/64bit:\$BOX64_LD_LIBRARY_PATH"
    export BOX64_LD_LIBRARY_PATH
    exec ${pkgs.box64}/bin/box64 "\$T/spectre/bin/64bit/spectre" "\$@"
    EOF
    chmod +x $out/bin/spectre64
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
    x86.numactl # libnuma.so.1 — Spectre 25.1 links it, not bundled
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
    # glibc C headers for Verilog-A ahdlcmi compilation (Spectre's bundled
    # cdsgcc include_next's <math.h> into /usr/include)
    mkdir -p rootfs/usr/include
    cp -a ${x86.glibc.dev}/include/. rootfs/usr/include/
    # C runtime startfiles for the ahdlcmi link (`ld: cannot find crti.o`).
    # The lib loop above deliberately skips *.o — right for runtime libs, but
    # `gcc -shared` needs crti.o/crtn.o out of /usr/lib64; cross-glibc ships
    # them in its out lib dir next to the .so linker scripts. (The scripts'
    # GROUP() entries use absolute store paths, so libc_nonshared.a resolves
    # through the virtiofs-mirrored /nix/store despite the *.a skip.)
    for f in ${x86.glibc}/lib/*.o; do
      [ -e "$f" ] && ln -sf "$f" rootfs/usr/lib64/
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
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
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
    # gcc search path for startfiles and -L: lets the cdsgcc link find
    # crti.o/crtn.o and the unversioned libc.so/libm.so linker scripts in the
    # rootfs /usr/lib64 (cdsgcc prepends its install dirs, preserving this).
    export LIBRARY_PATH="/usr/lib64''${LIBRARY_PATH:+:$LIBRARY_PATH}"
    # EE477 environment (equivalent of sourcing setup_ee477_ee577a_v2602.csh)
    export CDSBASE="$HOME/.cadence"
    export CDS_INST_DIR="$CDSBASE/IC251"
    export IC_HOME="$CDS_INST_DIR"
    export CDSHOME="$CDS_INST_DIR"
    export SPECTRE_HOME="$CDSBASE/spectre251"
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
    # Spectre's bundled ahdlcmi gnumake (x86_64, spectre/ahdlcmi/bin/gnumake)
    # segfaults under FEX on every invocation, which kills Verilog-A
    # compilation (VACOMP-1008). ahdlcmicompile honors AHDLCMI_MAKEPROGRAM:
    # it only falls back to the bundled binary when the var is unset, and
    # merely requires the target to exist as a file. Point it at the native
    # aarch64 GNU make linked into the guest /bin — make only orchestrates
    # (runs recipes via /bin/sh); the x86_64 cdsgcc toolchain under FEX does
    # the actual compiling/linking.
    export AHDLCMI_MAKEPROGRAM=/bin/make
    for p in "$IC_HOME/bin" "$IC_HOME/tools/bin" "$IC_HOME/tools/dfII/bin" "$SPECTRE_HOME/bin"; do
      case ":$PATH:" in
        *":$p:"*) ;;
        *) PATH="$p:$PATH" ;;
      esac
    done
    # user wrapper dir first: ~/.cadence/bin/virtuoso preloads the PDK libs
    export PATH="$HOME/.cadence/bin:$PATH"
    # muvm's attach path merges the CLIENT's PATH (host dirs) over the guest
    # base env; keep the guest tool dirs on PATH regardless (/bin holds the
    # tmpfs tool links: the uname shim, cadence-env-cleanup, ksh/tcsh/...).
    case ":$PATH:" in
      *":/bin:"*) ;;
      *) PATH="$PATH:/bin:/usr/bin" ;;
    esac
    export PATH
    exec ${pkgs.tcsh}/bin/tcsh "$@"
  '';

  # Guest-side session cleanup: reap the Cadence session daemons virtuoso
  # leaves behind (dashboard holds the session lock; see the virtuoso
  # wrapper) plus any orphaned processes — but only when no more than MAX
  # tcsh sessions remain, so an exiting session never kills the daemons of
  # sessions that are still alive. Invoked by the virtuoso wrapper (MAX=1:
  # its own parent tcsh still counts) and by the cadence-env wrapper after
  # an attached session exits (MAX=0).
  #
  # The orphan sweep must NEVER touch muvm-guest: it is the guest init
  # (PPid 1, running as the mapped user), so a blanket PPid==1 kill takes
  # the whole VM — and every attached session — down with it. The keeper
  # model wants the VM to survive session exits; only Cadence's own
  # orphaned daemons go.
  cadence-env-cleanup = pkgs.writeShellScript "cadence-env-cleanup" ''
    MAX="''${1:-0}"
    [ "$(/bin/pgrep -cx tcsh 2>/dev/null)" -le "$MAX" ] || exit 0
    for p in dashboard cdsNameServer cdsMsgServer cdsServIpc clsbd progressWidget cdsVncserver oaFSLockD perfUtilExtCtrl libManager libSelect; do
      /bin/pkill -9 -f "$p" 2>/dev/null
    done
    for d in /proc/[0-9]*; do
      pid=''${d##*/}
      [ "$pid" = "$$" ] && continue
      ppid=$(/bin/awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
      [ "$ppid" = "1" ] || continue
      [ "$(/bin/cat "$d/comm" 2>/dev/null)" = "muvm-guest" ] && continue
      /bin/kill -9 "$pid" 2>/dev/null
    done
    exit 0
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
    for tool in ${pkgs.gnused}/bin/* ${pkgs.gawk}/bin/* ${pkgs.gnugrep}/bin/* ${pkgs.procps}/bin/* ${pkgs.strace}/bin/* ${pkgs.gdb}/bin/* ${pkgs.psmisc}/bin/* ${pkgs.gnumake}/bin/*; do
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
    # Cadence wrapper scripts (cds_plat) run via #!/bin/csh
    ln -s ${pkgs.tcsh}/bin/tcsh /bin/csh
    ln -s ${pkgs.tcsh}/bin/tcsh /usr/bin/csh
    ln -s ${pkgs.ksh}/bin/ksh /usr/bin/ksh
    ln -s ${pkgs.tcsh}/bin/tcsh /usr/bin/tcsh
    ln -s ${pkgs.bash}/bin/bash /usr/bin/bash
    ln -s ${pkgs.hostname}/bin/hostname /bin/hostname
    ln -s ${pkgs.hostname}/bin/hostname /usr/bin/hostname
    ln -s ${pkgs.hostname}/bin/hostname /bin/domainname
    ln -s ${pkgs.hostname}/bin/hostname /usr/bin/domainname

    # ADE simulation spawns Xvfb and looks for /usr/bin/Xvfb (EXPLORER-9512).
    # Use the aarch64 build: it runs natively in the guest (no FEX), and the
    # x86_64 virtuoso talks plain X11 to it. Store deps resolve via the
    # virtiofs-mirrored host /nix/store, like the tools linked above.
    ln -s ${pkgs.xvfb}/bin/Xvfb /bin/Xvfb
    ln -s ${pkgs.xvfb}/bin/Xvfb /usr/bin/Xvfb
    # Session cleanup helper for the multi-session attach model (called by
    # the virtuoso wrapper and the cadence-env wrapper; see its header).
    ln -s ${cadence-env-cleanup} /bin/cadence-env-cleanup
    ln -s ${cadence-env-cleanup} /usr/bin/cadence-env-cleanup
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
      numactl # libnuma.so.1 — Spectre 25.1 links it, not bundled with the tool
      psmisc # pstree/killall — Spectre APS supervisor shells out to pstree
      glibc.dev # glibc C headers (/usr/include/math.h ...) — needed by Spectre's
                # bundled cdsgcc when compiling Verilog-A ahdlcmi modules
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
      # Virtuoso ADE simulation looks for Xvfb at /usr/bin (EXPLORER-9512).
      # xvfb is already in targetPkgs; pin the exact path so the check can
      # never regress.
      ln -sf ${pkgs.xvfb}/bin/Xvfb $out/usr/bin/Xvfb
      # Cadence launcher wrappers (.cdnWrapperIndep) run cds_plat, a csh
      # script with a #!/bin/csh shebang. tcsh is csh-compatible; provide the
      # name in the env's bin dir (in the FHS sandbox /bin -> /usr/bin).
      ln -sf ${pkgs.tcsh}/bin/tcsh $out/usr/bin/csh
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
      # C.UTF-8 (not plain C): a POSIX-locale JVM maps filenames as ASCII and
      # blows up on any non-ASCII path (InstallScape file chooser, Java NIO).
      export LANG=C.UTF-8 LC_ALL=C.UTF-8
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri"
      if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
        export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
        export __GLX_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/glx_vendor.d"
      fi
      export XLIB_SKIP_ARGB_VISUALS="1"
      # HiDPI: the Cadence tools are X11 apps shown through Xwayland; scale the
      # Qt UI by 1.25 (the asusg16 panel DPI) instead of the default 1x. Unlike
      # the muvm guest (which starts with a clean env), the FHS env inherits the
      # host's Plasma session env, which may carry per-screen/auto-scale Qt vars
      # that override QT_SCALE_FACTOR. Clear them so the explicit factor wins.
      unset QT_AUTO_SCREEN_SCALE_FACTOR
      unset QT_SCREEN_SCALE_FACTORS
      unset QT_DEVICE_PIXEL_RATIO
      export QT_ENABLE_HIGHDPI_SCALING=1
      export QT_SCALE_FACTOR=1.25
      export QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough
      # Cadence's bundled Qt5 exports every window menubar to the Plasma
      # global-menu widget: upstream Qt5 creates a QDBusMenuBar whenever the
      # com.canonical.AppMenu.Registrar service is on the session bus
      # (code inside libcdsQt5XcbQpa; there is no env kill-switch in Qt5),
      # and the export breaks when new windows open, leaving no menu
      # anywhere. Point the session bus at a dead address so Qt's DBus
      # connection fails: no registrar → menubars stay attached to the app
      # windows. Cadence tools don't use the session bus for anything else
      # (the muvm/FEX guest runs fine without one).
      export DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-cadence-env-no-dbus"
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
      export SPECTRE_HOME="$CDSBASE/spectre251"
    export OA_HOME="$CDS_INST_DIR/share/oa"
    # The OA libs are the x86_64 build (share/oa/lib/linux_rhel80_64), but the
    # launcher scripts run natively (aarch64) so `uname -m` reports aarch64 and
    # oaGetLibPath/sysname pick the aarch64 OA platform "lna64_rhel80" instead.
    # Pin the OA platform name to the x86_64 one.
    export OA_SYSNAME=linux_rhel80
      export CDS_AUTO_64BIT=ALL
      export CDS_Netlisting_Mode=Analog
      export SPECTRE_DEFAULTS=-E
    # IC paths BEFORE $SPECTRE_HOME/bin: the spectre tree ships generic
    # utilities (cds_root, cdspython, cdslmd, ...) that would otherwise shadow
    # the IC25.1 versions. spectre/aps themselves only exist in SPECTRE's bin,
    # so putting it last loses nothing.
    for p in "$IC_HOME/bin" "$IC_HOME/tools/bin" "$IC_HOME/tools/dfII/bin" "$SPECTRE_HOME/bin"; do
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

  # Timing-perturbation poller. DISABLED: it only perturbs timing (works "by
  # chance"), which is not a reliable fix. The real issue is Xwayland's
  # damage-extension circular list — see docs/cadence-fex.md.
  poller = "";

  # x86_64 hosts: run as the main user in the no-internet group (license
  # daemon / firewall isolation). aarch64 hosts: run inside the muvm microVM
  # under FEX (the 16K-page host kernel cannot run FEX directly).
  cadence-env =
    if isAarch64
    then
      pkgs.writeShellScriptBin "cadence-env" ''
        # Multi-session model: the VM is a resident "keeper" microVM. The
        # first launch boots it (its initial command is `/bin/sleep infinity`,
        # which never exits, so muvm keeps the VM alive independently of any
        # session); every launch — including the first — then attaches its
        # command to the running VM through muvm's built-in single-instance
        # server ($XDG_RUNTIME_DIR/krun/server). Concurrent GUI + CLI
        # sessions share one VM, and closing a terminal never kills other
        # sessions. `cadence-env --kill` stops the VM explicitly.
        #
        # muvm keys its lock + server socket on $XDG_RUNTIME_DIR, and other
        # tools run their own muvm VMs (steam-arm64 uses
        # <runtime>/steam-muvm) — so run ours in a private runtime dir. The
        # VMM is also identifiable by its unique -f rootfs argument: NEVER
        # pkill by the muvm path, that is steam's binary too.
        REAL_RUNTIME="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        XDG_RUNTIME_DIR="$REAL_RUNTIME/cadence-muvm"
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
        LOCK="$XDG_RUNTIME_DIR/muvm.lock"
        SOCK="$XDG_RUNTIME_DIR/krun/server"
        PROBE_ERR="$XDG_RUNTIME_DIR/probe.err"
        MUVM="${pkgs.muvm}/bin/muvm"
        SUDO=/run/wrappers/bin/sudo
        VMM_PAT="${fex-cadence-rootfs}"

        case "''${1:-}" in
          --help|-h)
            echo "usage: cadence-env [--kill|--help] [tcsh args...]"
            echo "  runs its arguments (or an interactive tcsh) inside the"
            echo "  shared cadence muvm VM, attaching if one is already up."
            echo "  --kill  stop the VM (graceful, then forceful)"
            exit 0 ;;
          --kill)
            pkill -TERM -f "$VMM_PAT" 2>/dev/null
            n=0
            while [ $n -lt 20 ] && pgrep -f "$VMM_PAT" >/dev/null 2>&1; do
              sleep 0.5
              n=$((n + 1))
            done
            if pgrep -f "$VMM_PAT" >/dev/null 2>&1; then
              pkill -KILL -f "$VMM_PAT" 2>/dev/null
            fi
            echo "cadence-env VM stopped."
            exit 0 ;;
        esac

        # muvm holds an exclusive flock on muvm.lock for the whole VM
        # lifetime; a stale (unlocked) file just means "boot", the same rule
        # muvm itself uses.
        vm_running() {
          [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null
        }

        stop_vm() {
          pkill -TERM -f "$VMM_PAT" 2>/dev/null
          n=0
          while [ $n -lt 10 ] && pgrep -f "$VMM_PAT" >/dev/null 2>&1; do
            sleep 0.5
            n=$((n + 1))
          done
          pkill -KILL -f "$VMM_PAT" 2>/dev/null
        }

        wait_socket() {
          # $1 = max half-seconds
          n=0
          while [ ! -S "$SOCK" ] && [ $n -lt "$1" ]; do
            sleep 0.5
            n=$((n + 1))
          done
          [ -S "$SOCK" ]
        }

        boot_vm() {
          # Safe only because the lock is free: no live VM can own the
          # socket (a concurrent boot in this window re-attaches harmlessly).
          rm -f "$SOCK"
          ${poller}
          # Boot the keeper VM detached. muvm runs in the no-internet group
          # so passt — which muvm spawns for the VM's networking — inherits
          # the group and the host iptables `-m owner --gid-owner
          # no-internet` REJECT rule makes any guest outbound connection
          # fail fast instead of hanging on timeouts. Cap the VM at 6 GiB
          # (muvm defaults to 80% of host RAM; steam's muvm VM claims the
          # same on this 12 GB machine, and a guest OOM kills the muvm
          # server while the host VMM — and its lock — survive: the wedged
          # state the probe below recovers from).
          nohup $SUDO -n -E -u ${config.local.username} -g no-internet "$MUVM" \
            -f ${fex-cadence-rootfs} \
            --mem=6144 \
            -m \
            -x ${cadence-env-guest-bin} \
            -e DISPLAY \
            -e XAUTHORITY \
            -- /bin/sleep infinity \
            >"$REAL_RUNTIME/cadence-env-vm.log" 2>&1 &
          wait_socket 120
        }

        # The guest server can die (e.g. guest OOM) while the host VMM and
        # its lock stay alive — every attach then fails with "could not
        # request launch to server: failed to fill whole buffer". Probe with
        # a plain detached exec (NO -i: muvm's interactive relay epolls
        # stdin, and stdin=/dev/null does not support epoll — `muvm -i <
        # /dev/null` fails with EPERM on a HEALTHY server). The detached
        # request exercises exactly the wedged-server path (connect + write
        # + read the OK reply) without touching stdin.
        server_healthy() {
          timeout 10 $SUDO -n -E -u ${config.local.username} -g no-internet "$MUVM" \
            -- /bin/true >/dev/null 2>"$PROBE_ERR"
        }

        if ! vm_running; then
          boot_vm || {
            echo "cadence-env: VM did not come up within 60s (log: $REAL_RUNTIME/cadence-env-vm.log)" >&2
            exit 1
          }
        else
          # Lock held: either still booting (a concurrent launch), or up.
          # Only a socket that never appears AND a failed probe is "wedged".
          if ! wait_socket 60; then
            recover=1
          elif ! server_healthy; then
            recover=1
          fi
        fi
        if [ "''${recover:-}" = 1 ]; then
          echo "cadence-env: running VM is wedged — restarting it" >&2
          stop_vm
          boot_vm || {
            echo "cadence-env: VM did not come up within 60s (log: $REAL_RUNTIME/cadence-env-vm.log)" >&2
            exit 1
          }
        fi

        # Attach. -i relays stdio and propagates the command's real exit
        # code (without it muvm detaches the command and always exits 0);
        # -t adds a pty, only possible with a terminal on stdin. Deliberately
        # NO `-e DISPLAY/-e XAUTHORITY`: the guest server env already carries
        # the x11-bridge values (DISPLAY=:1 + guest xauth) and client-sent
        # env would override them with unusable host values.
        # stdin: a terminal is relayed as-is (epoll-able, gets the pty);
        # anything else — notably /dev/null, which Plasma gives desktop
        # entries — is replaced with an at-EOF pipe, because muvm's relay
        # epolls stdin and /dev/null (or a regular file) fails with EPERM
        # ("could not request launch to server"). Batch commands (-c '...')
        # never read stdin, so immediate EOF is the right semantic.
        if [ -t 0 ]; then
          $SUDO -n -E -u ${config.local.username} -g no-internet "$MUVM" \
            -i -t \
            -- ${cadence-env-guest} "$@"
          rc=$?
        else
          $SUDO -n -E -u ${config.local.username} -g no-internet "$MUVM" \
            -i \
            -- ${cadence-env-guest} "$@" \
            < <(:)
          rc=$?
        fi
        # Last session gone? Reap the Cadence session daemons so the next
        # virtuoso starts clean (the virtuoso wrapper skips its sweep when
        # other sessions were still alive at its exit). stdin is the EOF
        # pipe for the same epoll reason as above.
        $SUDO -n -E -u ${config.local.username} -g no-internet "$MUVM" \
          -i -- /bin/cadence-env-cleanup 0 < <(:) >/dev/null 2>&1
        exit $rc
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
