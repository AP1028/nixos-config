{
  config,
  lib,
  pkgs,
  ...
}: {
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  # Mount removable media with sync so Dolphin/kio writes are flushed as they
  # go. This prevents the “copy finished but tail is still cached” corruption
  # when a USB drive is disconnected without ejecting. It only writes a small
  # udisks2 config file; no KDE rebuild is needed.
  services.udisks2.settings."mount_options.conf".defaults.defaults = "sync";

  services.displayManager.autoLogin = {
    enable = true;
    user = config.local.username;
  };

  environment.extraInit = ''
    export BALOO_SUSPEND=1
  '';
}
