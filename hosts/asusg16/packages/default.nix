{pkgs, ...}: {
  imports = [
    ../../../modules/packages/common

    ../../../modules/packages/graalvm.nix
    ../../../modules/packages/wechat.nix
    ../../../modules/packages/steam.nix
    ../../../modules/packages/flatpak-bottles.nix
    ../../../modules/packages/flatpak-baidunetdisk.nix
    ../../../modules/packages/flatpak-flatseal.nix
    ../../../modules/packages/davinci.nix
    ../../../modules/packages/onlyoffice.nix
    ../../../modules/packages/opencode.nix
    ../../../modules/packages/wpsoffice.nix
  ];

  environment.systemPackages = with pkgs; [
    brightnessctl
    dialog
    iproute2
    libnotify
    netcat-openbsd

    brave
    firefox
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

    hmcl
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

    freecad-wayland
    blender

    alejandra
    clang
    gcc
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
    temurin-bin-21
    temurin-bin-25

    pkgsCross.riscv32-embedded.buildPackages.gcc
    spike
    yosys

    (python3.withPackages (ps: with ps; [dbus-python pdftotext pygobject3 tkinter]))

    gimp3-with-plugins
    go-musicfox
    krita
    obs-studio
    obs-studio-plugins.obs-vkcapture
    bilibili
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
    input-remapper
    nvitop
    # crystal-dock

    texlive.combined.scheme-full

    quota
  ];

  programs.java = {
    enable = true;
    package = pkgs.graalvmPackages.graalvm-oracle_25;
  };
}
