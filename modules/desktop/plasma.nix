{
  config,
  lib,
  pkgs,
  ...
}: {
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  services.displayManager.autoLogin = {
    enable = true;
    user = config.local.username;
  };

  environment.extraInit = ''
    export BALOO_SUSPEND=1
  '';
}
