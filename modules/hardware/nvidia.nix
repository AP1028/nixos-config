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
        # The stock nvidia-offload script is replaced by the one in
        # modules/hardware/cardwire.nix, which adds CARDWIRE_FORCE_DGPU so
        # Cardwire's eBPF LSM hook unblocks /dev/nvidia* for the process.
        enableOffloadCmd = false;
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
    dynamicBoost.enable = lib.mkDefault true;
  };

  # tuned for NVIDIA power management; disable TLP to avoid conflicts
  services.tuned.enable = true;
  services.tlp.enable = lib.mkOverride 500 false;

  # Blacklist nvidia_wmi_ec_backlight — it breaks backlight control on ASUS
  boot.blacklistedKernelModules = ["nvidia_wmi_ec_backlight"];
  boot.extraModprobeConfig = ''
    install nvidia_wmi_ec_backlight ${pkgs.coreutils}/bin/true
  '';

  # Disable power-profiles-daemon (tuned handles it)

  services.power-profiles-daemon.enable = false;

  # Keeping the dGPU asleep is now Cardwire's job (see
  # modules/hardware/cardwire.nix): its eBPF LSM hooks deny /dev/nvidia* to
  # every process that has not been explicitly allowed, so no environment pin
  # is needed to stop rogue WebKit / Electron / Vulkan clients from waking it.
  #
  # `__GLX_VENDOR_LIBRARY_NAME = "mesa"` is kept as a cheap default: it is
  # overridden per process by nvidia-offload and by Cardwire's Switcheroo
  # environment, so offloaded apps still get NVIDIA GLX.
  #
  # The EGL vendor pin that used to live here had to go: with
  # CARDWIRE_FORCE_DGPU the iGPU is hidden from the app, so a hard
  # Mesa-only EGL list would leave offloaded EGL clients with no usable
  # device. Without it libglvnd tries 10_nvidia.json first (denied instantly
  # with -ENOENT for blocked apps, so it falls back to Mesa and the dGPU never
  # resumes) and succeeds for allowed apps.
  environment.variables = {
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
  };

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    nvtopPackages.nvidia
  ];
}
