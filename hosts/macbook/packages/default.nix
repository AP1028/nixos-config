{pkgs, inputs, ...}: let
  wechat-uos-wrapped = pkgs.symlinkJoin {
    name = "wechat-uos-desktop-fix";
    paths = [pkgs.wechat-uos];
    postBuild = ''
      rm -f $out/share/applications/*.desktop
      cp ${pkgs.wechat-uos}/share/applications/*.desktop $out/share/applications/
      chmod +w $out/share/applications/*.desktop
      sed -i "s|^Exec=.*|Exec=$out/bin/wechat-uos %U|" $out/share/applications/*.desktop
    '';
  };
in {
  imports = [
    ../../../modules/packages/opencode.nix
    ../../../modules/packages/steam-asahi.nix
    ../../../modules/packages/bottles-cpak.nix
    ../../../modules/packages/flatpak-netease.nix
  ];

  programs.nix-ld.enable = true;
  programs.steam-asahi.enable = true;
  services.flatpak.enable = true;

  environment.systemPackages = with pkgs; [
    wget
    git
    fastfetch
    brave

    nmap
    zenmap

    vscode
    neovim
    nixd
    alejandra

    tmux
    gcc
    clang
    gnumake
    universal-ctags
    distrobox
    libnotify

    aircrack-ng
    usbutils
    pciutils
    iw
    wirelesstools

    smartmontools
    powertop

    (python3.withPackages (ps:
      with ps; [
        tkinter
        dbus-python
        pygobject3
      ]))

    wechat-uos-wrapped
    go-musicfox
    libreoffice-qt-stable
    kdePackages.okular
    gimp3-with-plugins
    krita
    # nixpkgs dropped firefox-esr-140; take it from the stable track (see the
    # package file for why zotero cannot build against firefox-esr-153).
    (pkgs.callPackage ../../../packages/zotero-fx140.nix {
      firefox-esr-140-unwrapped =
        inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.firefox-esr-140-unwrapped;
    })
    moonlight-qt
    bilibili

    htop
    killall
    mpv

    # DeepSeek Harness (dsh CLI + Electron desktop). Native aarch64 build:
    # upstream ships linux-arm64 runtime and native-addon assets.
    (pkgs.callPackage ../../../packages/deepseek-harness { })

    openvpn
    tigervnc
    box64
    muvm
    gamescope
    gdb

    # Xwayland with the composite restore blit NOPed — root fix for the
    # Cadence-close DE freeze (docs/cadence-freeze.md). hiPrio shadows the real
    # xwayland's bin/Xwayland in /run/current-system/sw/bin, the path kwin
    # launches. Active after the next login.
    (pkgs.lib.hiPrio (pkgs.callPackage ../../../packages/patched-xwayland.nix { }))
  ];
}
