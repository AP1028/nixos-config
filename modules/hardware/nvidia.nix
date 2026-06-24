{
  config,
  lib,
  pkgs,
  ...
}: {
  # Allow GPU to enter deeper sleep states when idle
  boot.kernelParams = [
    "nvidia.NVreg_EnableS0ixPowerManagement=1"
  ];

  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;

    # Open-source kernel modules (required for Blackwell GPUs)
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # PRIME render offload: Intel iGPU drives display, NVIDIA handles heavy apps
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
    dynamicBoost.enable = lib.mkDefault true;
  };

  # tuned for NVIDIA power management; disable TLP to avoid conflicts
  services.tuned.enable = true;
  services.tlp.enable = lib.mkOverride 500 false;

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    nvtopPackages.nvidia
  ];

  # Blacklist nvidia_wmi_ec_backlight — it breaks backlight control on ASUS
  boot.blacklistedKernelModules = ["nvidia_wmi_ec_backlight"];
  boot.extraModprobeConfig = ''
    install nvidia_wmi_ec_backlight ${pkgs.coreutils}/bin/true
  '';

  # Disable power-profiles-daemon (tuned handles it)

  services.power-profiles-daemon.enable = false;

  # Default to iGPU (Mesa) — use nvidia-offload for NVIDIA.
  # This keeps the dGPU free for VFIO passthrough without rogue
  # WebKit / Electron / Vulkan processes holding /dev/nvidia*.
  environment.variables = {
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
  };
}
