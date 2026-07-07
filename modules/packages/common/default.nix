{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    git
    wget
    fastfetch
    htop
    pciutils
    unzip
    nmap
    killall
    iotop
  ];
}
