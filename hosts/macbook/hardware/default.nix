{
  config,
  lib,
  pkgs,
  ...
}: {
  nix.settings.substituters = [
    "https://nixos-apple-silicon.cachix.org"
    "https://cache.nixos.org"
  ];
  nix.settings.trusted-public-keys = [
    "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  ];

  boot.kernelModules = ["88x2bu"];
  boot.extraModulePackages = [config.boot.kernelPackages.rtl88x2bu];

  hardware.asahi.peripheralFirmwareDirectory = /. + "${config.local.configDir}/hosts/macbook/firmware";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.efi.efiSysMountPoint = "/efi";
}
