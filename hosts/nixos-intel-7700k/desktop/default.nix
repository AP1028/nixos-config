{
  config,
  lib,
  pkgs,
  ...
}: {
  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;

  programs.firefox.enable = true;
}
