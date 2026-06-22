{
  config,
  lib,
  pkgs,
  ...
}: {
  # Enable Secure Boot via lanzaboote
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/efi";
  boot.lanzaboote.enable = true;
  boot.lanzaboote.pkiBundle = "/var/lib/sbctl";

  environment.systemPackages = with pkgs; [
    sbctl # Secure Boot key management
  ];
}
