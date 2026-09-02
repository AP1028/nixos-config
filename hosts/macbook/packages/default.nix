{pkgs, ...}: let
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
    ../../../modules/packages/steam-arm64.nix
  ];

  programs.nix-ld.enable = true;
  programs.steam-arm64.enable = true;

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
    zotero
    moonlight-qt

    htop
    killall
    mpv

    openvpn
    tigervnc
    box64
    muvm
  ];
}
