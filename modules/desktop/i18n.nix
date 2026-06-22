{
  config,
  lib,
  pkgs,
  ...
}: {
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.waylandFrontend = true;
    fcitx5.addons = with pkgs; [
      qt6Packages.fcitx5-chinese-addons
      fcitx5-gtk
      kdePackages.fcitx5-qt
    ];
  };

  systemd.user.units."app-org.fcitx.Fcitx5@autostart.service".enable = false;
  services.automatic-timezoned.enable = false;
}
