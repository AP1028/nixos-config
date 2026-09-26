{
  config,
  pkgs,
  ...
}: let
  nvVersion = builtins.replaceStrings ["."] ["-"] config.hardware.nvidia.package.version;
  bottlesFix = pkgs.writeText "bottles-connection-fix.py" (builtins.readFile ./bottles-connection-fix.py);
in {
  services.flatpak.enable = true;
  fonts.fontDir.enable = true;

  systemd.services.bottles-network-fix = {
    description = "Bottles: apply connectivity-check fallback URLs (upstream #4543)";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      target=/var/lib/flatpak/app/com.usebottles.bottles/x86_64/stable/active/files/share/bottles/bottles/backend/utils/connection.py
      if [ -f "$target" ] && ! grep -q "_check_urls" "$target"; then
        rm -f "$target"
        install -m 444 "${bottlesFix}" "$target"
      fi
    '';
  };

  services.flatpak.packages = [
    "com.usebottles.bottles"

    "org.freedesktop.Platform.GL.nvidia-${nvVersion}"
    "org.freedesktop.Platform.GL32.nvidia-${nvVersion}"

    "org.freedesktop.Platform.VulkanLayer.vkBasalt//25.08"
    "org.freedesktop.Platform.VulkanLayer.gamescope//25.08"
    "org.freedesktop.Platform.VulkanLayer.MangoHud//25.08"
    "org.freedesktop.Platform.VulkanLayer.OBSVkCapture//25.08"
  ];

  # Bottles is no longer pinned to the iGPU here: cardwire decides per process.
  # A plain Bottles launch is blocked from /dev/nvidia* and falls back to Mesa,
  # and `bottles-dgpu` (below) forces the dGPU for a gaming session. Keeping the
  # Intel-only ICD list would defeat that: with CARDWIRE_FORCE_DGPU the iGPU is
  # hidden, so an Intel-only Vulkan list would leave the sandbox with no device.
  services.flatpak.overrides.settings."com.usebottles.bottles" = {
    Context = {
      filesystems = ["host"];
      devices = ["usb"];
    };
    Environment = {
      FLATPAK_GL_DRIVERS = "host";
    };
  };

  # Explicit "run Bottles on the dGPU" launcher. cardwire unblocks /dev/nvidia*
  # and hides the iGPU for the whole session, and the vendor variables make
  # GL/Vulkan pick NVIDIA rather than falling back to Mesa.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "bottles-dgpu" ''
      exec ${pkgs.flatpak}/bin/flatpak run \
        --env=CARDWIRE_FORCE_DGPU=1 \
        --env=__NV_PRIME_RENDER_OFFLOAD=1 \
        --env=__GLX_VENDOR_LIBRARY_NAME=nvidia \
        --env=__VK_LAYER_NV_optimus=NVIDIA_only \
        --env=VK_LOADER_DRIVERS_SELECT='*nvidia*,*nouveau*' \
        com.usebottles.bottles "$@"
    '')
    (pkgs.makeDesktopItem {
      name = "bottles-dgpu";
      desktopName = "Bottles (dGPU)";
      comment = "Bottles with the NVIDIA dGPU unblocked for gaming";
      exec = "bottles-dgpu %U";
      icon = "com.usebottles.bottles";
      categories = ["Game"];
    })
  ];

  services.flatpak.overrides.settings."com.baidu.NetDisk" = {
    Context = {
      filesystems = ["home"];
    };
    Environment = {
      __GLX_VENDOR_LIBRARY_NAME = "mesa";
      __EGL_VENDOR_LIBRARY_FILENAMES = "/usr/share/glvnd/egl_vendor.d/50_mesa.json";
      FLATPAK_GL_DRIVERS = "host";
    };
  };
}
