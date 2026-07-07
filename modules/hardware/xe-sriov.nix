# Testing Xe SR-IOV with kernel 7.1+
{
  config,
  lib,
  pkgs,
  ...
}: let
  igpuScripts = pkgs.callPackage ../../packages/igpu-sriov-scripts.nix {};
in {
  boot.extraModulePackages = [
    (pkgs.xe-sriov.overrideAttrs (oldAttrs: {
      postPatch =
        (oldAttrs.postPatch or "")
        + ''
          # Kernel 7.1: drm_buddy was renamed to gpu_buddy (since 6.12).
          # The print helpers (drm_buddy_print) are DRM wrappers that still exist.
          # The include path (<drm/drm_buddy.h>) still exists and pulls in <linux/gpu_buddy.h>.
          for f in $(grep -rl -e "drm_buddy" -e "DRM_BUDDY" drivers/gpu/drm/xe/); do
            # Protect DRM print wrappers and the include path from global rename
            sed -i 's|drm_buddy_print|__BUDDY_PRINT__|g' "$f"
            sed -i 's|drm_buddy.h|__BUDDY_HEADER__|g' "$f"
            # Global rename: drm_buddy* -> gpu_buddy*
            sed -i 's|drm_buddy|gpu_buddy|g' "$f"
            sed -i 's|DRM_BUDDY|GPU_BUDDY|g' "$f"
            # Restore protected names
            sed -i 's|__BUDDY_PRINT__|drm_buddy_print|g' "$f"
            sed -i 's|__BUDDY_HEADER__|drm_buddy.h|g' "$f"
          done

          # Kernel 7.1: dma_buf move_notify -> invalidate_mappings
          sed -i 's|dma_buf_move_notify|dma_buf_invalidate_mappings|g' drivers/gpu/drm/xe/xe_bo.c
          sed -i 's|\.move_notify|\.invalidate_mappings|g' drivers/gpu/drm/xe/xe_dma_buf.c

          # Kernel 7.1: dma_fence.lock split into extern_lock/inline_lock union
          sed -i 's|fence->dma\.lock|fence->dma.extern_lock|g' drivers/gpu/drm/xe/xe_hw_fence.c
          # Kernel 7.1: dma_fence.lock -> dma_fence_spinlock()
          sed -i 's|fence->lock|dma_fence_spinlock(fence)|g' drivers/gpu/drm/xe/xe_sched_job.c

          # Kernel 7.1: intel_vsec_register / pmt_callbacks take struct device* not pci_dev*
          sed -i 's|xe_pmt_telem_read(struct pci_dev \*pdev|xe_pmt_telem_read(struct device *dev|' drivers/gpu/drm/xe/xe_vsec.c
          sed -i 's|pdev_to_xe_device(pdev)|pdev_to_xe_device(to_pci_dev(dev))|g' drivers/gpu/drm/xe/xe_vsec.c
          sed -i 's|intel_vsec_register(pdev,|intel_vsec_register(\&pdev->dev,|g' drivers/gpu/drm/xe/xe_vsec.c
          # Update header declaration
          sed -i 's|xe_pmt_telem_read(struct pci_dev \*pdev|xe_pmt_telem_read(struct device *dev|' drivers/gpu/drm/xe/xe_vsec.h
          # Update callers: remove to_pci_dev() wrapper (dev is already struct device*)
          for f in drivers/gpu/drm/xe/xe_debugfs.c drivers/gpu/drm/xe/xe_hwmon.c; do
            sed -i 's|xe_pmt_telem_read(to_pci_dev(\([^)]*\))|xe_pmt_telem_read(\1|g' "$f"
          done

          # Kernel 7.1: drm_plane_colorop_*_init gained a funcs parameter
          sed -i 's|drm_plane_colorop_[a-z0-9_]*_init(dev, &colorop->base, plane,|\0 NULL,|g' drivers/gpu/drm/i915/display/intel_color_pipeline.c

          # Kernel 7.1: INTEL_GMCH_CTRL removed (pre-SNB, never used by Xe)
          sed -i 's|INTEL_GMCH_CTRL|SNB_GMCH_CTRL|g' drivers/gpu/drm/i915/display/intel_vga.c

          # Enable SR-IOV for Arrow Lake (ARL reuses MTL descriptor)
          sed -i '/PLATFORM(METEORLAKE),/a \	.has_sriov = true,' drivers/gpu/drm/xe/xe_pci.c
        '';
    }))
  ];
  # Force Xe driver (disable i915) and enable SR-IOV support
  boot.kernelParams = [
    "i915.force_probe=!*"
    "xe.force_probe=*"

    # Reserve firmware memory for up to 4 Virtual Functions
    "xe.max_vfs=4"
  ];

  # Blacklist i915 so Xe can claim the GPU
  boot.blacklistedKernelModules = ["i915"];
  boot.initrd.kernelModules = ["xe"];

  # Intel media and compute packages for VA-API and OpenCL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      intel-vaapi-driver
      intel-media-driver
    ];
  };

  # On-demand VF management scripts (replaces the auto-spawn systemd service).
  # VFs are not created at boot — spin them up only when needed:
  #   igpu-vf-up [N]     Create N VFs and bind to vfio-pci
  #   igpu-vf-down       Destroy all VFs (refuses if VM is using them)
  #   igpu-vf-status     Show current VF state
  environment.systemPackages = [
    igpuScripts.igpu-vf-up
    igpuScripts.igpu-vf-down
    igpuScripts.igpu-vf-status
  ];
}
