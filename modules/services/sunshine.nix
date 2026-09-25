{
  config,
  lib,
  pkgs,
  ...
}: {
  # Sunshine game streaming server (Moonlight compatible)
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true; # CAP_SYS_ADMIN for KMS capture on Wayland
    openFirewall = true;
  };

  # Grant access to /dev/uinput (controller emulation) and /dev/input
  users.users.${config.local.username}.extraGroups = ["input"];
  hardware.uinput.enable = true;

  # Sunshine's KMS capture only reads the primary plane. KWin 6.7 enables
  # overlay planes by default on i915/Xe, which offloads window surfaces to
  # planes kmsgrab can't see: in the stream, an interacted/damaged window shows
  # only its frame (the content area shows what's behind it). Force KWin to
  # composite everything into the primary plane instead.
  environment.sessionVariables.KWIN_USE_OVERLAYS = "0";
}
