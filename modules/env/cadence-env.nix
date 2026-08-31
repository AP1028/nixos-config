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
  cds-apr = pkgs.stdenv.mkDerivation {
    pname = "cds-apr-libm";
    version = pkgs.apr.version;
    src = pkgs.apr;
    nativeBuildInputs = [pkgs.patchelf];
    unpackPhase = "true";
    buildPhase = ''
      mkdir -p $out/lib
      cp -a $src/lib/libapr-1.so.0* $out/lib/
      chmod +w $out/lib/libapr-1.so.0.7.6
      patchelf --add-needed libm.so.6 $out/lib/libapr-1.so.0.7.6
    '';
    installPhase = "true";
  };

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
      xorg.xvfb
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
      ln -sf ${cds-apr}/lib/libapr-1.so.0.7.6 $out/usr/lib64/libapr-1.so.0.5.1
      ln -sf ${cds-apr}/lib/libapr-1.so.0.7.6 $out/usr/lib64/libapr-1.so.0
      # old-SONAME OpenLDAP compat for Cadence's liblog4cxx
      ln -sf ${pkgs.openldap}/lib/libldap.so.2 $out/usr/lib64/libldap_r-2.4.so.2
      ln -sf ${pkgs.openldap}/lib/liblber.so.2 $out/usr/lib64/liblber-2.4.so.2
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
      # saSecurity requires the licensing-agent mode disabled and the VSM
      # framework vars set before it will attempt the license checkout.
      export CDS_LIC_USE_AGENT=0
      export VSM_FWK=VSM95011
      export VSM_ITK=VSM12141
      export LD_LIBRARY_PATH="/usr/lib64:/usr/lib:/run/opengl-driver/lib:/run/opengl-driver-32/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      # EE477 environment (equivalent of sourcing setup_ee477_ee577a_v2602.csh)
      export CDSBASE="$HOME/.cadence"
      export CDS_INST_DIR="$CDSBASE/IC251"
      export IC_HOME="$CDS_INST_DIR"
      export CDSHOME="$CDS_INST_DIR"
      export SPECTRE_HOME="$CDSBASE/spectre181"
      export OA_HOME="$CDS_INST_DIR/share/oa"
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

  # ── Wrapper: run as the main user in no-internet group ──────────

  cadence-env = pkgs.writeShellScriptBin "cadence-env" ''
    exec /run/wrappers/bin/sudo -E -u ${config.local.username} -g no-internet ${cadence-env-raw}/bin/cadence-env "$@"
  '';
in {
  environment.systemPackages = [cadence-env];

  # Allow passwordless sudo for the cadence-env wrapper (needed for group switching)
  security.sudo.extraRules = [
    {
      users = [config.local.username];
      runAs = "ALL";
      commands = [
        {
          command = "${cadence-env-raw}/bin/cadence-env";
          options = ["NOPASSWD" "SETENV"];
        }
      ];
    }
  ];
}
