# Pins (due to dependency breakage on nixos-unstable):
#   clash-verge — unpinned as of 2.5.2 (2.5.1 blank proxy regression); flake
#   input old-nixpkgs kept as fallback pin if a future version breaks again

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
    ../../../modules/packages/opencode.nix
    ../../../modules/packages/codex.nix
    ../../../modules/packages/wpsoffice.nix
    ../../../modules/packages/controller-rebind.nix
  ];

  environment.systemPackages = with pkgs; [
    (pkgs.callPackage ../../../packages/ysm-java { })
    (pkgs.callPackage ../../../packages/claw-code { })
    (pkgs.callPackage ../../../packages/amulet-map-editor { })
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
    motrix-next
    qbittorrent
    zotero
    qalculate-qt
    pinta
    audacity
    poppler-utils

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

    freecad
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
    bilibili
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

    # nixpkgs postInstall copies bin/rpc-server, but llama.cpp b10000+ installs
    # it as ggml-rpc-server; point the rename at the installed path instead.
    ((llama-cpp.override {
      cudaSupport = true;
      rpcSupport = true;
    }).overrideAttrs (old: {
      # stable split-graph uids so the RPC graph cache (GRAPH_RECOMPUTE) engages
      patches = (old.patches or [ ]) ++ [ ../../../packages/patches/rpc-graph-cache.patch ];
      postInstall = builtins.replaceStrings
        ["cp bin/rpc-server $out/bin/llama-rpc-server"]
        ["cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server"]
        old.postInstall;
    }))

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
