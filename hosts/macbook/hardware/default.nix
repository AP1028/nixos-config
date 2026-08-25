{
  config,
  lib,
  pkgs,
  ...
}: {
  nix.settings.substituters = [
    "https://nixos-apple-silicon.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
    "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
  ];

  hardware.asahi.enable = true;
  hardware.asahi.peripheralFirmwareDirectory = /. + "${config.local.configDir}/hosts/macbook/firmware";

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = lib.mkForce 10;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.efi.efiSysMountPoint = "/efi";
}
