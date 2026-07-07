{
  config,
  lib,
  pkgs,
  ...
}: let
  igpuScripts = pkgs.callPackage ../../packages/igpu-sriov-scripts.nix {};
in {
  # Out-of-tree i915 SR-IOV kernel module for GPU virtualization.
  # Using the upstream kernel-v7.1 branch, which supports kernel 7.1 natively,
  # so the sketchy sed-based patching below is no longer needed.
  boot.extraModulePackages = [
    pkgs.i915-sriov
    # (pkgs.i915-sriov.overrideAttrs (oldAttrs: {
    #   postPatch =
    #     (oldAttrs.postPatch or "")
    #     + ''
    #       # Kernel 7.1: pagevec.h removed, header is unused in i915
    #       sed -i '/^#include <linux\/pagevec.h>$/d' drivers/gpu/drm/i915/gt/intel_gtt.h
    #       sed -i '/^#include <linux\/pagevec.h>$/d' drivers/gpu/drm/i915/gem/i915_gem_shmem.c
    #       sed -i '/^#include <linux\/pagevec.h>$/d' drivers/gpu/drm/i915/i915_gpu_error.c
    #
    #       # Kernel 7.1: drm_buddy -> gpu_buddy (since 6.12)
    #       for f in $(grep -rl -e "drm_buddy" -e "DRM_BUDDY" drivers/gpu/drm/i915/ || true); do
    #         test -z "$f" && continue
    #         sed -i 's|drm_buddy_print|__BUDDY_PRINT__|g' "$f"
    #         sed -i 's|drm_buddy_block_print|__BUDDY_BLOCK_PRINT__|g' "$f"
    #         sed -i 's|drm_buddy.h|__BUDDY_HEADER__|g' "$f"
    #         sed -i 's|drm_buddy|gpu_buddy|g' "$f"
    #         sed -i 's|DRM_BUDDY|GPU_BUDDY|g' "$f"
    #         sed -i 's|__BUDDY_PRINT__|drm_buddy_print|g' "$f"
    #         sed -i 's|__BUDDY_BLOCK_PRINT__|drm_buddy_block_print|g' "$f"
    #         sed -i 's|__BUDDY_HEADER__|drm_buddy.h|g' "$f"
    #       done
    #
    #       # Kernel 7.1: dma_buf move_notify -> invalidate_mappings
    #       grep -rl "dma_buf_move_notify\|\.move_notify" drivers/gpu/drm/i915/ | xargs -r sed -i 's|dma_buf_move_notify|dma_buf_invalidate_mappings|g; s|\.move_notify|\.invalidate_mappings|g' || true
    #
    #       # Kernel 7.1: zap_vma_ptes removed and zap_vma_range not exported
    #       sed -i 's|zap_vma_ptes(vma, addr, (r\.pfn - pfn) << PAGE_SHIFT);||g' drivers/gpu/drm/i915/i915_mm.c
    #       sed -i 's|zap_vma_ptes(vma, addr, r\.pfn << PAGE_SHIFT);||g' drivers/gpu/drm/i915/i915_mm.c
    #
    #       # Kernel 7.1: dma_fence.lock -> dma_fence_spinlock()
    #       sed -i 's|fence->lock|dma_fence_spinlock(fence)|g' drivers/gpu/drm/i915/gt/intel_breadcrumbs.c
    #       sed -i 's|fence->lock|dma_fence_spinlock(fence)|g; s|prev->lock|dma_fence_spinlock(prev)|g' drivers/gpu/drm/i915/i915_active.c
    #
    #       # Kernel 7.1: drm_plane_colorop_*_init gained a funcs parameter
    #       sed -i 's|drm_plane_colorop_[a-z0-9_]*_init(dev, &colorop->base, plane,|\0 NULL,|g' drivers/gpu/drm/i915/display/intel_color_pipeline.c
    #
    #       # Kernel 7.1: INTEL_GMCH_CTRL removed (pre-SNB, never used on modern HW)
    #       sed -i 's|INTEL_GMCH_CTRL|SNB_GMCH_CTRL|g' drivers/gpu/drm/i915/display/intel_vga.c
    #     '';
    # }))
  ];

  # Force i915 (not Xe) and enable SR-IOV support
  boot.kernelParams = [
    "i915.force_probe=*"
    "xe.force_probe=!*"

    # GuC/HuC firmware loading — required for SR-IOV
    "i915.enable_guc=3"

    # Reserve firmware memory for up to 4 Virtual Functions
    "i915.max_vfs=4"

    # =3 forces the Intel HDR backlight interface, which this eDP panel needs.
    # With =1 the DPCD backlight interface leaves intel_backlight powered down
    # (bl_power=4) and brightness control does nothing. Kernel drm log recommends =3.
    "i915.enable_dpcd_backlight=3"

    # Prevent deep display sleep states (DC6 PHY refclk failures on Arrow Lake)
    "i915.enable_dc=2"

    # PSR is broken on Arrow Lake with out-of-tree i915-sriov
    "i915.enable_psr=0"
  ];

  # Blacklist Xe driver so i915 can claim the GPU
  boot.blacklistedKernelModules = ["xe"];
  boot.initrd.kernelModules = ["i915"];

  # Intel media and compute packages for VA‑API and OpenCL
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
