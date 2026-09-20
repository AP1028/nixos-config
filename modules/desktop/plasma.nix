{
  config,
  lib,
  pkgs,
  ...
}: {
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  # X11 stays available for `flip-session` (drop-in in /etc/sddm.conf.d),
  # but Wayland Plasma is the default session.
  services.xserver.enable = true;
  services.displayManager.defaultSession = "plasma";

  # Removable media are mounted async (udisks2 default). Do NOT set a global
  # `sync` default here: it makes every Dolphin/kio write wait for a disk
  # FLUSH CACHE, which capped USB HDD copies at ~6 MB/s (measured 73 ms per
  # flush on the Seagate). Tradeoff: eject before unplugging or the cached
  # tail is lost.

  environment.extraInit = ''
    export BALOO_SUSPEND=1
  '';
}
