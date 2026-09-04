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
    ../../../modules/packages/r2modman.nix
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
    (pkgs.callPackage ../../../packages/deepseek-harness { })
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
    gamescope
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
    openconnect
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
    # ((llama-cpp.override {
    #   cudaSupport = true;
    #   rpcSupport = true;
    # }).overrideAttrs (old: {
    #   # b10331: adds DeepSeek V4 DSpark speculative decoding (PR #25784),
    #   # which the MXFP4 cluster uses to batch-verify 5 tokens per pass.
    #   version = "10331";
    #   src = fetchFromGitHub {
    #     owner = "ggml-org";
    #     repo = "llama.cpp";
    #     tag = "b10331";
    #     hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
    #     leaveDotGit = true;
    #     postFetch = old.src.postFetch;
    #   };
    #   # stable split-graph uids so the RPC graph cache (GRAPH_RECOMPUTE) engages
    #   patches = (old.patches or [ ]) ++ [ ../../../packages/patches/rpc-graph-cache.patch ../../../packages/patches/rpc-dspark-draft-path.patch ../../../packages/patches/rpc-debug-tensor-name.patch ../../../packages/patches/rpc-dsv4-compressed-cpu.patch ../../../packages/patches/rpc-server-repack.patch ];
    #   # b10331 moved the rpc-server to tools/rpc (target ggml-rpc-server) and
    #   # only installs it with LLAMA_TOOLS_INSTALL=ON
    #   cmakeFlags = old.cmakeFlags ++ [ "-DLLAMA_TOOLS_INSTALL=ON" ];
    #   npmDeps = fetchNpmDeps {
    #     name = "llama-cpp-10331-npm-deps";
    #     src = fetchFromGitHub {
    #       owner = "ggml-org";
    #       repo = "llama.cpp";
    #       tag = "b10331";
    #       hash = "sha256-0uquzGXrLbuFFUauNl0R9tjfxLt5UBEC4cqNHnmdux4=";
    #       leaveDotGit = true;
    #       postFetch = old.src.postFetch;
    #     };
    #     patches = [ ../../../packages/patches/rpc-graph-cache.patch ];
    #     preBuild = ''
    #       pushd tools/ui
    #     '';
    #     hash = "sha256-FHvd2bMvBc9EXrJEzu8EN78oUVSLcOKYCc0232V+L4A=";
    #   };
    #   postInstall = builtins.replaceStrings
    #     ["cp bin/rpc-server $out/bin/llama-rpc-server"]
    #     ["cp $out/bin/ggml-rpc-server $out/bin/llama-rpc-server"]
    #     old.postInstall;
    # }))

    texliveFull
    dotnet-sdk_9

    quota
    smartmontools
    e2fsprogs
    ntfsprogs

    acpica-tools
    powertop
    linuxPackages_latest.turbostat

    libreoffice-qt-stable

    wireshark
    wireshark-cli

    speedtest
    speedtest-cli

    tigervnc
    tcsh
    ksh
  ];

  programs.java = {
    enable = true;
    package = pkgs.zulu21;
  };

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib ];
}
