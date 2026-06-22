{pkgs, ...}: let
  nvmeScripts = pkgs.callPackage ../../../packages/nvme-scripts.nix {};
  gpuVfioScripts = pkgs.callPackage ../../../packages/gpu-vfio-scripts.nix {};
  nvidiaProcess = pkgs.callPackage ../../../packages/nvidia-process.nix {};
in {
  environment.systemPackages = [
    nvmeScripts.nvme-to-host
    nvmeScripts.nvme-to-vm
    gpuVfioScripts.gpu-to-vfio
    gpuVfioScripts.gpu-to-host
    gpuVfioScripts.gpu-vfio-status
    gpuVfioScripts.gpu-vfio-apply
    nvidiaProcess.nvidia-process-check
    nvidiaProcess.nvidia-process-kill
  ];
}
