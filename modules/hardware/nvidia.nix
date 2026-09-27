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
  # There used to be two *global* "prefer the iGPU" pins here
  # (__GLX_VENDOR_LIBRARY_NAME=mesa and a Mesa-only EGL vendor list). They were a
  # workaround for a denied device still being *attempted*: libglvnd walked the
  # EGL vendor list, tried 10_nvidia.json, and ANGLE/CEF treated the resulting
  # eglInitialize failure as fatal, so Steam's GPU process crash-looped. Both are
  # gone, for two reasons:
  #
  #   1. cardwire now hides the NVIDIA user-space vendor from blocked processes
  #      (manifests *and* driver libraries, per process —
  #      packages/patches/cardwire-hide-nvidia-userspace.patch), so a blocked
  #      process never sees the vendor to attempt it, and an *allowed* process
  #      sees the real vendor list. The global pin is redundant; the LSM is the
  #      boundary.
  #   2. They break a MUX flip hard. With the display driven by the dGPU
  #      ("discrete only"), `__GLX_VENDOR_LIBRARY_NAME=mesa` forces libglvnd to
  #      load Mesa's GLX — which has no driver for the NVIDIA-only display — and
  #      the Mesa-only EGL list cuts off NVIDIA EGL entirely: GLX/EGL clients fail
  #      instead of using the GPU that is actually present.
  #
  # Per-process overrides are unaffected and remain the way to ask for the dGPU
  # explicitly: nvidia-offload (and DaVinci) set the NVIDIA GLX/EGL vendors for
  # themselves, and Vulkan has its own ICD list, so an allowed game still
  # enumerates the NVIDIA Vulkan device.
  #
  # Note for MUX/"discrete only" use: when the iGPU stays enumerated it keeps
  # gpu id 0 (cardwire numbers GPUs by PCI address), so cardwire's smart mode
  # would still block the dGPU that is now driving the display. Put cardwire in
  # Hybrid mode (no blocking) before relying on a dGPU-only MUX state — or, if the
  # firmware hides the iGPU, the dGPU becomes id 0 and smart mode blocks nothing
  # (the LSM always allows gpu id 0). The per-tool envs elsewhere
  # (modules/env/{game,cadence,synopsys}-env.nix, flatpak-bottles.nix) still pin
  # Mesa for their own processes and would need the same treatment if those tools
  # are used while the display is on the dGPU.

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    nvtopPackages.nvidia
  ];
}
