{
  pkgs,
  ...
}: {
  networking.hostName = "nixos-intel-7700k";
  networking.networkmanager.enable = true;
}
