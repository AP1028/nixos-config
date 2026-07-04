{...}: {
  networking.hostName = "macbook";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.backend = "iwd";
}
