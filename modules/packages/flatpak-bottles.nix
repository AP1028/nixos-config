{
  config,
  pkgs,
  ...
}: let
  nvVersion = builtins.replaceStrings ["."] ["-"] config.hardware.nvidia.package.version;
in {
  services.flatpak.enable = true;
  fonts.fontDir.enable = true;

  services.flatpak.packages = [
    "com.usebottles.bottles"

    "org.freedesktop.Platform.GL.nvidia-${nvVersion}"
    "org.freedesktop.Platform.GL32.nvidia-${nvVersion}"

    "org.freedesktop.Platform.VulkanLayer.vkBasalt//25.08"
    "org.freedesktop.Platform.VulkanLayer.gamescope//25.08"
    "org.freedesktop.Platform.VulkanLayer.MangoHud//25.08"
    "org.freedesktop.Platform.VulkanLayer.OBSVkCapture//25.08"
  ];
}
