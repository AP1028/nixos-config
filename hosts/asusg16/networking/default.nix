{lib, pkgs, ...}: {
  networking.hostName = "asusg16";
  networking.domain = "local";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.backend = "iwd";
  networking.networkmanager.plugins = with pkgs; [
    networkmanager-openvpn
    networkmanager-openconnect
  ];
  system.nssDatabases.hosts = lib.mkOrder 450 ["files"];
}
