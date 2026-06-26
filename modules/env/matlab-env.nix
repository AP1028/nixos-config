{
  config,
  lib,
  pkgs,
  ...
}: let
  # FHS environment for MATLAB (Wayland + glibc compatibility)
  matlab-env-raw = pkgs.buildFHSEnv {
    name = "matlab-env";
    targetPkgs = pkgs:
      with pkgs; [
        bash
        coreutils
        zlib
        stdenv.cc.cc
        glib
        gcc
        gnumake
        binutils
        procps
        unzip
        linux-pam
        libselinux
        libxcrypt-legacy
        udev
        cacert
        nss
        nspr
        alsa-lib
        cups
        dbus
        pango
        cairo
        atk
        gtk3
        gdk-pixbuf
        libsndfile
        libXext
        libX11
        libXrender
        libXtst
        libXi
        libXft
        libxcb
        freetype
        fontconfig
        libSM
        libICE
        libXt
        libXmu
        libXrandr
        libXcursor
        libXcomposite
        libXdamage
        libXfixes
        libXxf86vm
        libXinerama
        libdrm
        mesa
        libgbm
        libxkbcommon
        wayland
        libxshmfence
        # mesa.drivers is deprecated; mesa already included above
        expat
        strace
        ltrace
        file
        glibcInfo
        fribidi
        gtk2
        pixman
        libtirpc
        libuuid
        libGL
        libXau
        libXdmcp
        libXfont2
        xcbutilwm
        xcbutilimage
        xcbutilkeysyms
        xcbutilrenderutil
        xcbutil
        qt5.qtbase
        qt5.qtsvg
        qt5.qtgamepad
        gtkmm3
        atkmm
        glibmm
        libsigcxx
        iproute2
        net-tools
        glibcLocales
      ];
    profile = ''
      export IN_FHS_ENV="matlab-env"
      export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
      export _JAVA_AWT_WM_NONREPARENTING=1
      export MATLAB_WEBSERVER_USE_SYSTEM_NSS=1
    '';
    runScript = "zsh";
  };

  # Wrapper to launch the FHS env as the main user in no-internet group
  matlab-env = pkgs.writeShellScriptBin "matlab-env" ''
    exec /run/wrappers/bin/sudo -E -u ${config.local.username} -g no-internet ${matlab-env-raw}/bin/matlab-env "$@"
  '';

  # Convenience commands that launch matlab/mex inside the FHS sandbox
  matlab-wrapper = pkgs.writeShellScriptBin "matlab" ''
    exec ${matlab-env}/bin/matlab-env -c 'matlab "$@"' -- "$@"
  '';

  mex-wrapper = pkgs.writeShellScriptBin "mex" ''
    exec ${matlab-env}/bin/matlab-env -c 'mex "$@"' -- "$@"
  '';
in {
  environment.systemPackages = [
    matlab-env
    matlab-wrapper
    mex-wrapper
  ];

  # Passwordless sudo for the matlab-env wrapper (group switching)
  security.sudo.extraRules = [
    {
      users = [config.local.username];
      runAs = "ALL";
      commands = [
        {
          command = "${matlab-env-raw}/bin/matlab-env";
          options = ["NOPASSWD" "SETENV"];
        }
      ];
    }
  ];
}
