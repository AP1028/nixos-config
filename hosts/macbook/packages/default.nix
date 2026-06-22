{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    wget
    git
    fastfetch
    brave

    nmap
    zenmap
    flclash

    vscode-fhs
    neovim
    nixd
    alejandra

    aircrack-ng
    usbutils
    pciutils
    iw
    wirelesstools

    (python3.withPackages (ps:
      with ps; [
        tkinter
        dbus-python
        pygobject3
      ]))

    wechat-uos
    go-musicfox
    libreoffice
    kdePackages.okular
    gimp3-with-plugins
    krita
    zotero
    moonlight-qt
  ];
}
