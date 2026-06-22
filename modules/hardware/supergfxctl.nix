{
  config,
  lib,
  pkgs,
  ...
}: {
  # supergfxctl has been uninstalled.
  # GPU VFIO/host switching is now handled by the scripts in virtualization.nix:
  #   gpu-to-vfio   —  bind NVIDIA GPU to vfio-pci  (for VM)
  #   gpu-to-host   —  return NVIDIA GPU to nvidia    (for host)
  #   gpu-vfio-status —  show current binding state
  #
  # The kernel cmdline param below ensures vfio-pci.ids is set at boot so
  # the GPU auto-binds to vfio-pci.  On the host you then run:
  #   sudo gpu-to-host     to use the GPU for compute / games
  #   sudo gpu-to-vfio     to pass it back to the VM

  # gpu-to-vfio / gpu-to-host use fuser (from psmisc), not lsof.
  # psmisc is already pulled in by the scripts in virtualization.nix.
}
