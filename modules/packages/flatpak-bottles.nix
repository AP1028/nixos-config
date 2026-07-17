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

  services.flatpak.overrides.settings."com.usebottles.bottles" = {
    Context = {
      filesystems = ["host"];
      devices = ["usb"];
    };
    Environment = {
      VK_ICD_FILENAMES = "/usr/share/vulkan/icd.d/intel_icd.x86_64.json";
      __GLX_VENDOR_LIBRARY_NAME = "mesa";
      __EGL_VENDOR_LIBRARY_FILENAMES = "/usr/share/glvnd/egl_vendor.d/50_mesa.json";
      FLATPAK_GL_DRIVERS = "host";
    };
  };
}
