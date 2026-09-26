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
        # modules/hardware/cardwire.nix, which adds CARDWIRE_ALLOW=1 so
        # Cardwire's eBPF LSM hook unblocks /dev/nvidia* for the process
        # (both GPUs stay visible; only the vendor vars select NVIDIA).
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

  # Keeping the dGPU asleep is Cardwire's job (see
  # modules/hardware/cardwire.nix): its eBPF LSM hooks deny /dev/nvidia* to
  # every process that has not been explicitly allowed.
  #
  # Both vendor pins below are "prefer the iGPU" defaults rather than a
  # security boundary — the LSM is the boundary. They are here because a denied
  # device must not be *attempted*: libglvnd walks the EGL vendor list starting
  # with 10_nvidia.json, and when cardwire denies that device the eglInitialize
  # failure is fatal to ANGLE/CEF instead of falling back to Mesa. Measured:
  # Steam's GPU process crash-loops ("Disabling GPU acceleration:
  # Disabled/CrashCount") and the window is painted ~13-20 s late; the first
  # such event in the entire Steam log is 2026-09-25 20:46, hours after cardwire
  # was installed and this pin was dropped. With the pin, CEF initialises Mesa
  # immediately.
  #
  # Per-process overrides still win: nvidia-offload (and DaVinci) set the NVIDIA
  # GLX/EGL vendors for themselves, and Vulkan is a separate ICD list — a game
  # that is Allowed can still enumerate and use the NVIDIA Vulkan device.
  environment.variables = {
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
  };

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    nvtopPackages.nvidia
  ];
}
