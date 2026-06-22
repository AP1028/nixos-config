# DISABLED: does not support WIFI
{
  config,
  lib,
  pkgs,
  ...
}: {
  # networking.bridges.br0.interfaces = ["wlan0"];
  # networking.interfaces.br0.useDHCP = true;
}
