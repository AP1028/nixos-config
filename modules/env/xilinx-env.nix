{
  config,
  lib,
  pkgs,
  ...
}: {
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "xvlog" ''
      exec xilinx-env -c 'xvlog "$@"' -- "$@"
    '')
    (writeShellScriptBin "vivado" ''
      exec xilinx-env -c 'vivado "$@"' -- "$@"
    '')
    (writeShellScriptBin "xsim" ''
      exec xilinx-env -c 'xsim "$@"' -- "$@"
    '')

    (buildFHSEnv {
      name = "xilinx-env";
      targetPkgs = pkgs: with pkgs; [
        util-linux.lib
        pixman
        libpng
        util-linux
        ncurses5
        pkgsi686Linux.ncurses5
        ncurses
        libxcrypt-legacy

        bash
        coreutils
        zlib
        stdenv.cc.cc
        nettools
        procps
        unzip
        graphviz

        gcc
        binutils
        gnumake

        libXext libX11 libXrender libXtst libXi libXft libxcb
        freetype fontconfig glib gtk2 gtk3
      ];
      profile = ''
        export IN_FHS_ENV="xilinx-env"
        if [ ! -f /lib/libtinfo.so.5 ]; then
          ln -sf /lib/libncurses.so.5 /lib/libtinfo.so.5
          ln -sf /lib/libncurses.so.5 /lib/libtinfo.so
        fi
        if [ -d /lib32 ] && [ ! -f /lib32/libtinfo.so.5 ]; then
          ln -sf /lib32/libncurses.so.5 /lib32/libtinfo.so.5
        fi
        export LD_LIBRARY_PATH=/lib:/lib64:/lib32:$LD_LIBRARY_PATH
        if [ -f /opt/2025.2/Vivado/settings64.sh ]; then
          source /opt/2025.2/Vivado/settings64.sh
        elif [ -f /home/${config.local.username}/.vivado/2025.2/Vivado/settings64.sh ]; then
          source /home/${config.local.username}/.vivado/2025.2/Vivado/settings64.sh
        fi
      '';
      runScript = "zsh";
    })
  ];
}
