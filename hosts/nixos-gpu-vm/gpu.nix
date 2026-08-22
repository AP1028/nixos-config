{
  config,
  lib,
  pkgs,
  ...
}: {
  # 2x RTX 2080 Ti (Turing, sm_75) passed through from the Proxmox host with
  # NVLink. Turing is still supported by the latest stable NVIDIA driver and
  # current nixpkgs CUDA packages, so there are no vGPU-era CUDA/driver pins
  # here (the previous vGPU grid driver setup is gone with the P40s).
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {
    # Latest stable driver still supports Turing.
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Closed-source kernel modules for the 2080 Ti; modern drivers require an
    # explicit choice here.
    open = false;
  };

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
    nvtopPackages.nvidia
  ];
}
