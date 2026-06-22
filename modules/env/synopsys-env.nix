{
  config,
  lib,
  pkgs,
  ...
}: let
  # ── Helper derivations ──────────────────────────────────────────

  # Synopsys SCL's license manager uses inode numbers from readdir("/") to
  # validate the host. Inside an FHS env the root inode differs, so this
  # LD_PRELOAD shim patches readdir to return consistent inode values.
  scl-root-inode-fix = pkgs.stdenv.mkDerivation {
    name = "scl-root-inode-fix";
    src = pkgs.writeText "fix.c" ''
      #define _GNU_SOURCE
      #include <stdio.h>
      #include <stdlib.h>
      #include <dirent.h>
      #include <dlfcn.h>
      #include <string.h>

      static int is_root = 0;
      static int d_ino = -1;
      static DIR *(*orig_opendir)(const char *name);
      static int (*orig_closedir)(DIR *dirp);
      static struct dirent *(*orig_readdir)(DIR *dirp);

      DIR *opendir(const char *name) {
          if (strcmp(name, "/") == 0) is_root = 1;
          return orig_opendir(name);
      }

      int closedir(DIR *dirp) {
          is_root = 0;
          return orig_closedir(dirp);
      }

      struct dirent *readdir(DIR *dirp) {
          struct dirent *r = orig_readdir(dirp);
          if (is_root && r) {
              if (strcmp(r->d_name, ".") == 0) r->d_ino = d_ino;
              else if (strcmp(r->d_name, "..") == 0) r->d_ino = d_ino;
          }
          return r;
      }

      static __attribute__((constructor)) void init_methods() {
          orig_opendir = dlsym(RTLD_NEXT, "opendir");
          orig_closedir = dlsym(RTLD_NEXT, "closedir");
          orig_readdir = dlsym(RTLD_NEXT, "readdir");

          DIR *d = orig_opendir("/");
          if (d) {
              struct dirent *e = orig_readdir(d);
              while (e) {
                  if (strcmp(e->d_name, ".") == 0) {
                      d_ino = e->d_ino;
                      break;
                  }
                  e = orig_readdir(d);
              }
              orig_closedir(d);
          }

          if (d_ino == -1) {
              puts("Failed to determine root directory inode number");
              exit(EXIT_FAILURE);
          }
      }
    '';
    unpackPhase = "true";
    buildPhase = "$CC -shared -fPIC -o libscl_fix.so $src -ldl";
    installPhase = ''
      mkdir -p $out/lib
      cp libscl_fix.so $out/lib/
    '';
  };

  # Synopsys tools link against libxml2.so.2 (older SONAME); nixpkgs ships
  # libxml2.so.16. This compat layer provides both.
  libxml2-compat = pkgs.runCommand "libxml2-compat" {} ''
    mkdir -p $out/lib
    cp -a ${pkgs.libxml2.out}/lib/. $out/lib/
    chmod u+w $out/lib
    ln -sf libxml2.so.16 $out/lib/libxml2.so.2
  '';

  # Launch Firefox/Evince outside the FHS env — unset LD_LIBRARY_PATH so they
  # don't pick up the sandboxed libraries
  firefox-clean = pkgs.writeShellScriptBin "firefox" ''
    #!/bin/sh
    unset LD_LIBRARY_PATH
    exec ${pkgs.firefox}/bin/firefox "$@"
  '';

  evince-clean = pkgs.writeShellScriptBin "evince" ''
    #!/bin/sh
    unset LD_LIBRARY_PATH
    exec ${pkgs.evince}/bin/evince "$@"
  '';

  # ── FHS environment ─────────────────────────────────────────────

  synopsys-env-raw = pkgs.buildFHSEnv {
    name = "synopsys-env";
    targetPkgs = pkgs: (with pkgs; [
      glibc
      zlib
      gcc-unwrapped.lib
      stdenv.cc.cc.lib
      bash
      tcsh
      coreutils
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
      libxcb
      libxshmfence
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
      libxml2-compat
      libXaw
      libtool
      xdpyinfo
      firefox-clean
      evince-clean
      mesa-demos
      openjdk11
      ncurses5

      ksh
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
      sqlite
    ]);

    extraBuildCommands = ''
      mkdir -p $out/usr/bin
      ln -sf tcsh $out/usr/bin/csh
    '';

    extraBindMounts = {
      "/run/opengl-driver" = "/run/opengl-driver";
      "/run/opengl-driver-32" = "/run/opengl-driver-32";
      "/run/opengl-driver/share" = "/run/opengl-driver/share";
      "/home/${config.local.username}/.synopsys/tcad/sentaurus/R_2020.09a/tcad/current/linux64/lib/libGL.so.1" = "${pkgs.libglvnd}/lib/libGL.so.1";
      "/home/${config.local.username}/.synopsys/tcad/sentaurus/R_2020.09a/tcad/current/linux64/lib/libGL.so" = "${pkgs.libglvnd}/lib/libGL.so.1";
      "/home/${config.local.username}/.synopsys/tcad/sentaurus/R_2020.09a/tcad/current/linux64/lib/libstdc++.so.6" = "${pkgs.gcc-unwrapped.lib}/lib/libstdc++.so.6";
    };

    profile = ''
      export XKB_CONFIG_ROOT=/usr/share/X11/xkb
      export IN_FHS_ENV="synopsys-env"
      unset http_proxy https_proxy ftp_proxy rsync_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY RSYNC_PROXY ALL_PROXY no_proxy NO_PROXY
      export LANG=C LC_ALL=C
      export LD_PRELOAD="${scl-root-inode-fix}/lib/libscl_fix.so"
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri"
      if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
        export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
        export __GLX_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/glx_vendor.d"
      fi
      export STHOME="/home/${config.local.username}/.synopsys/tcad/sentaurus/R_2020.09a"
      export STROOT="$STHOME"
      export STDB="$HOME/STDB"
      export SWB_DYNAMIC_MENU="1"
      export ICWBEV_USER="SENTAURUS"
      export ICWB_USER="SENTAURUS"
      export LM_LICENSE_FILE="27080@localhost"
      export SNPSLMD_LICENSE_FILE="27080@localhost"
      export XLIB_SKIP_ARGB_VISUALS="1"
      export ICWBEV_HOME="/home/${config.local.username}/.synopsys/icwbev/icwbev_plus/Q-2019.12-SP3"
      export PATH="$PATH:$STROOT/bin:$ICWBEV_HOME/bin"
      export LD_LIBRARY_PATH="/run/opengl-driver/lib:/run/opengl-driver-32/lib:/lib:/usr/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}:$ICWBEV_HOME/lib/linux64/:$STROOT/tcad/current/linux64/lib"
    '';
    runScript = "tcsh";
  };

  # ── Wrapper: run as the main user in no-internet group ──────────

  synopsys-env = pkgs.writeShellScriptBin "synopsys-env" ''
    exec /run/wrappers/bin/sudo -E -u ${config.local.username} -g no-internet ${synopsys-env-raw}/bin/synopsys-env "$@"
  '';
in {
  environment.systemPackages = [synopsys-env];

  # Allow passwordless sudo for the synopsys-env wrapper (needed for group switching)
  security.sudo.extraRules = [
    {
      users = [config.local.username];
      runAs = "ALL";
      commands = [
        {
          command = "${synopsys-env-raw}/bin/synopsys-env";
          options = ["NOPASSWD" "SETENV"];
        }
      ];
    }
  ];

  # Synopsys SCL license server, bound to localhost only
  systemd.services.synopsys-license = {
    description = "Synopsys SCL License Server";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      User = config.local.username;
      Group = "users";
      WorkingDirectory = "/home/${config.local.username}/.synopsys/scl/scl/2025.03/linux64/bin";
      ExecStart = "${synopsys-env-raw}/bin/synopsys-env -c './lmgrd -c synopsys.lic -z -l debug.log'";
      Restart = "always";
      RestartSec = 10;
      IPAddressDeny = "any";
      IPAddressAllow = ["127.0.0.1" "::1"];
    };
  };
}
