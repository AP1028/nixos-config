{
  config,
  lib,
  pkgs,
  ...
}: let
  # Environment for a process that must render/compute on the NVIDIA dGPU.
  # This is the set Cardwire's Switcheroo shim advertises for "Launch using
  # Discrete Graphics Card", plus an explicit NVIDIA EGL vendor file.
  dgpuEnv = {
    # Cardwire: unblock /dev/nvidia* for this process and hide the iGPU from it.
    CARDWIRE_FORCE_DGPU = "1";

    # Vendor offload variables (libglvnd / Vulkan loader).
    __NV_PRIME_RENDER_OFFLOAD = "1";
    __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    __VK_LAYER_NV_optimus = "NVIDIA_only";
    VK_LOADER_DRIVERS_SELECT = "*nvidia*,*nouveau*";

    # nvidia.nix no longer pins the EGL vendor list globally (see the comment
    # there), so offloaded EGL clients select NVIDIA explicitly.
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
  };

  dgpuExports = lib.concatLines (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") dgpuEnv
  );
in {
  # Cardwire installs eBPF LSM hooks that make the blocked GPU's device nodes
  # (/dev/dri/renderD*, /dev/nvidia*, nvidia modeset/uvm, GPU sysfs attributes)
  # return -ENOENT to every process that has not been explicitly allowed. This
  # is what replaces the per-application bwrap / GLX / EGL / Vulkan-ICD
  # workarounds: a blocked GPU cannot be woken by Vulkan ICD enumeration, an
  # Electron renderer, a GTK app or nvtop, no matter how it is packaged.
  #
  # Smart mode blocks the dGPU by default and allows it per application:
  #   - KDE's "Launch using Discrete Graphics Card" (Switcheroo D-Bus shim)
  #   - `nvidia-offload` / `CARDWIRE_FORCE_DGPU=1` / `CARDWIRE_ALLOW=1`
  #   - the per-application list in cardwire-gui
  services.cardwired = {
    enable = true;
    settings = {
      auto_apply_gpu_state = true;
      # Also hides /dev/nvidiactl and /dev/nvidia-modeset; required to stop
      # Vulkan clients and nvtop from waking a suspended dGPU.
      experimental_nvidia_block = true;
      battery_auto_switch = true;
      battery_auto_switch_mode = "smart"; # mode to use while on AC power
      # This chassis wires HDMI to the NVIDIA GPU (card0-HDMI-A-2); without
      # this, a blocked dGPU means no external output on that port. While a
      # dGPU-attached display is plugged in, Cardwire temporarily falls back to
      # hybrid mode (docked = on AC, so the battery cost is moot).
      external_display_auto_switch = true;
    };
  };

  # Cardwire persists the active mode, but a fresh state starts in hybrid. Set
  # smart explicitly at boot; battery_auto_switch takes over from there.
  systemd.services.cardwire-set-smart = {
    description = "Set Cardwire GPU mode to smart";
    wantedBy = ["multi-user.target"];
    after = ["cardwired.service"];
    requires = ["cardwired.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${lib.getExe' config.services.cardwired.package "cardwire"} set smart";
  };

  environment.systemPackages = [
    # Replaces the stock nvidia-offload script (disabled in nvidia.nix): the
    # same vendor variables plus the Cardwire routing variable, without which
    # the LSM hook keeps /dev/nvidia* blocked. Also how CUDA/CLI work reaches
    # the dGPU: `nvidia-offload python train.py`.
    (pkgs.writeShellScriptBin "nvidia-offload" ''
      ${dgpuExports}
      exec "$@"
    '')

    # nvtop opens /dev/nvidiactl unconditionally, so it needs an explicit allow.
    (lib.hiPrio (pkgs.writeShellScriptBin "nvtop" ''
      export CARDWIRE_ALLOW=1
      exec ${pkgs.nvtopPackages.nvidia}/bin/nvtop "$@"
    ''))

    # Start Steam on the dGPU; every game it spawns inherits the routing
    # variable. Plain `steam` stays on the iGPU, and only games approved in
    # cardwire-gui (or given `CARDWIRE_FORCE_DGPU=1 %command%` launch options)
    # reach the dGPU.
    (pkgs.writeShellScriptBin "steam-dgpu" ''
      export PATH=/run/current-system/sw/bin''${PATH:+:$PATH}
      export CARDWIRE_FORCE_DGPU=1
      exec steam "$@"
    '')
    (pkgs.makeDesktopItem {
      name = "steam-dgpu";
      desktopName = "Steam (dGPU)";
      comment = "Steam with every launched game forced onto the NVIDIA dGPU";
      exec = "steam-dgpu %U";
      icon = "steam";
      categories = ["Game"];
    })
  ];
}
