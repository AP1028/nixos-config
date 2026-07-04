{pkgs, ...}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs; [
    wget
    git
    fastfetch
    brave

    nmap
    zenmap
    flclash

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

    wechat-uos
    go-musicfox
    libreoffice-qt6-fresh
    kdePackages.okular
    gimp3-with-plugins
    krita
    zotero
    moonlight-qt

    htop
    killall
    mpv
  ];
}
