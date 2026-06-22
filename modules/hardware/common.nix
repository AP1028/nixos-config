{
  config,
  lib,
  pkgs,
  ...
}: {
  hardware.bluetooth.enable = true;
  hardware.cpu.intel.updateMicrocode = true;
  services.fstrim.enable = true;
}
