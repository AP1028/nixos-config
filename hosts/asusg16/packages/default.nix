# Pins (due to dependency breakage on nixos-unstable):
#   freecad     — pinned via flake input qemu-nixpkgs (pdal fails with new GDAL API)
#   clash-verge — pinned to 2.4.7 via flake input old-nixpkgs (2.5.1 blank proxy regression)

{
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../../../modules/packages/common

    ../../../modules/packages/graalvm.nix
    ../../../modules/packages/wechat.nix
    ../../../modules/packages/steam.nix
    ../../../modules/packages/flatpak-bottles.nix
    ../../../modules/packages/flatpak-baidunetdisk.nix
    ../../../modules/packages/flatpak-flatseal.nix
    ../../../modules/packages/flatpak-netease.nix
    ../../../modules/packages/electron-hide-nvidia.nix
    ../../../modules/packages/davinci.nix
    ../../../modules/packages/bilibili.nix
    # ../../../modules/packages/onlyoffice.nix
    ../../../modules/packages/opencode.nix
    ../../../modules/packages/wpsoffice.nix
    ../../../modules/packages/controller-rebind.nix
  ];

  environment.systemPackages = with pkgs; [
    (pkgs.callPackage ../../../packages/ysm-java { })
    brightnessctl
    dialog
    iproute2
    libnotify
    netcat-openbsd

    brave
    firefox
    mpv
    kdePackages.okular
    marktext
    qbittorrent
    zotero
    qalculate-qt
    pinta
    audacity

    discord
    feishu
    zoom-us

    (hmcl.overrideAttrs (old: {
      runtimeDeps = old.runtimeDeps ++ [ pkgs.stdenv.cc.cc.lib ];
    }))
    owmods-cli
    owmods-gui
    steam-run
    (prismlauncher.override {
      jdks = with pkgs; [
        temurin-bin-8
        temurin-bin-17
        temurin-bin-21
        temurin-bin-25
        graalvm-ce_21
        graalvmPackages.graalvm-oracle_17
        graalvmPackages.graalvm-oracle_25
      ];
    })

    freecad  # pinned via overlay (see top of file)
    blender

    alejandra
    clang
    gcc
    gnumake
    valgrind
    neovim
    nixd
    tmux
    universal-ctags
    vscode

    graalvmPackages.graalvm-oracle_25
    graalvmPackages.graalvm-oracle_17
    graalvm-ce_21
    temurin-bin-8
    temurin-bin-17
    (lib.hiPrio temurin-bin-21)
    temurin-bin-25

    pkgsCross.riscv32-embedded.buildPackages.gcc
    spike
    dtc
    yosys
    verilator

    (python3.withPackages (ps: with ps; [dbus-python pdftotext pygobject3 tkinter]))

    gimp3-with-plugins
    go-musicfox
    krita
    obs-studio
    obs-studio-plugins.obs-vkcapture
    bili-live-tool
    bilibili-tui
    biliup-rs

    aircrack-ng
    freerdp
    iw
    openvpn
    usbutils
    wirelesstools
    zenmap

    parsec-bin
    moonlight-qt

    distrobox
    nvitop

    texliveFull
    dotnet-sdk_9

    quota
    smartmontools
    e2fsprogs
    ntfsprogs

    acpica-tools
    powertop
    linuxPackages_latest.turbostat

    libreoffice-qt6-fresh

    wireshark
    wireshark-cli

    speedtest
    speedtest-cli
  ];

  programs.java = {
    enable = true;
    package = pkgs.zulu21;
  };

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib ];
}
