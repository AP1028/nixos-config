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

  # Bottles used to be pinned to the iGPU with VK_ICD_FILENAMES=<intel_icd>,
  # __GLX_VENDOR_LIBRARY_NAME=mesa and __EGL_VENDOR_LIBRARY_FILENAMES=<50_mesa>
  # (commit e90a6a4). Those keys are gone from `services.flatpak.overrides`
  # below, but deleting them from the Nix config is not enough: nix-flatpak only
  # *merges* into the on-disk file and keeps keys it no longer manages —
  # flatpak-managed-install says so explicitly:
  #
  #   # When a setting or file is removed from the Nix config the active
  #   # override file is left untouched, preserving any direct edits ...
  #
  # so /var/lib/flatpak/overrides/com.usebottles.bottles still carried the old
  # values. On this machine the BIOS MUX is set to discrete-only: the iGPU is
  # still enumerated (/dev/dri/card1, i915) but cannot present, so forcing the
  # Intel Vulkan ICD plus Mesa GLX/EGL made GL/Vulkan initialisation fail
  # (MESA: zink: could not create swapchain / VK_ERROR_INITIALIZATION_FAILED)
  # and GTK died before the window appeared:
  #
  #   Gdk-Message: Error 71 (Protocol error) dispatching to Wayland display.
  #
  # Flatseal cannot undo this: it writes the *user* override
  # (~/.local/share/flatpak/overrides/), while these sit in the *system* one,
  # and Flatpak merges system-then-user — a key absent from the user layer does
  # not cancel one the system layer set. Retract them explicitly instead.
  systemd.services.bottles-drop-stale-igpu-env = {
    description = "Bottles: retract the stale iGPU-pinned GL/Vulkan Flatpak overrides";
    wantedBy = ["multi-user.target"];
    # Must land after nix-flatpak has re-merged the override file, otherwise the
    # merge can put the old values back on the next boot.
    after = ["flatpak-managed-install.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${config.services.flatpak.package}/bin/flatpak override --system \
        --unset-env=VK_ICD_FILENAMES \
        --unset-env=__GLX_VENDOR_LIBRARY_NAME \
        --unset-env=__EGL_VENDOR_LIBRARY_FILENAMES \
        com.usebottles.bottles
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
  # Unblocked by default means it falls back to Mesa; when you actually want it
  # on the dGPU, allow the Bottles process in cardwire-gui (Allowed = both GPUs
  # available, the application picks) — no wrapper needed. Keeping an Intel-only
  # ICD list would make that impossible, so it is gone.
  services.flatpak.overrides.settings."com.usebottles.bottles" = {
    Context = {
      filesystems = ["host"];
      devices = ["usb"];
    };
    Environment = {
      FLATPAK_GL_DRIVERS = "host";
    };
  };

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
