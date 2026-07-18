{pkgs, ...}: let
  nvmeScripts = pkgs.callPackage ../../../packages/nvme-scripts.nix {};
  gpuVfioScripts = pkgs.callPackage ../../../packages/gpu-vfio-scripts.nix {};
  nvidiaProcess = pkgs.callPackage ../../../packages/nvidia-process.nix {};
  dgpuPowerScripts = pkgs.callPackage ../../../packages/dgpu-power-scripts.nix {};
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
    dgpuPowerScripts.dgpu-off
    dgpuPowerScripts.dgpu-on
    dgpuPowerScripts.dgpu-power-status
  ];

  # Firmware may power the dGPU back on when resuming from suspend.
  # Re-assert the off state on wake (same guard supergfxd implements).
  powerManagement.resumeCommands = ''
    if [ -r /var/lib/dgpu-power/state ]; then
      read -r mode addr < /var/lib/dgpu-power/state || true
      case "$mode" in
        off-asus)
          if [ -w /sys/devices/platform/asus-nb-wmi/dgpu_disable ]; then
            echo 1 > /sys/devices/platform/asus-nb-wmi/dgpu_disable || true
          fi
          ;;
        off-slot)
          for slot in /sys/bus/pci/slots/*/; do
            if [ -n "''${addr:-}" ] && grep -qx "$addr" "$slot/address" 2>/dev/null; then
              echo 0 > "$slot/power" || true
            fi
          done
          ;;
      esac
    fi
  '';
}
