{
  config,
  lib,
  pkgs,
  ...
}: {
  # Grant USB access to Flydigi (Vader/Apex) and Xbox controllers
  services.udev.extraRules = ''
    KERNEL=="hidraw*", ATTRS{idVendor}=="28de", MODE="0666"
    KERNEL=="hidraw*", ATTRS{idVendor}=="045e", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2d99", MODE="0666"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2d99", ATTRS{idProduct}=="f023", MODE="0666"
  '';
}
