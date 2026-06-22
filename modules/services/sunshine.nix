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
}
