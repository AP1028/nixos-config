{
  config,
  lib,
  pkgs,
  ...
}: {
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

  # Spawn 1 SR-IOV Virtual Function and bind it to vfio-pci for VM passthrough
  systemd.services.intel-i915-sriov = {
    description = "Provision Intel i915 SR-IOV VF and Bind to vfio-pci";
    wantedBy = ["multi-user.target"];
    after = ["systemd-modules-load.service"];
    path = [pkgs.kmod]; # Ensures 'modprobe' is available in the script path
    script = ''
      # The primary Intel iGPU is located at 0000:00:02.0
      IGPU_SYSFS="/sys/bus/pci/devices/0000:00:02.0/sriov_numvfs"

      # Ensure vfio-pci module is loaded
      modprobe vfio-pci

      # Wait up to 10 seconds for the i915 driver to expose the sysfs node
      for i in {1..10}; do
        if [ -f "$IGPU_SYSFS" ]; then
          break
        fi
        sleep 1
      done

      # If the node exists and no VFs are spawned, spawn 1 VF
      if [ -f "$IGPU_SYSFS" ] && [ "$(cat $IGPU_SYSFS)" -eq "0" ]; then
        echo 1 > "$IGPU_SYSFS"

        # Wait a moment for the kernel to initialize the new VF (usually 0000:00:02.1)
        sleep 2

        VF_ADDRESS="0000:00:02.1"
        VF_SYSFS="/sys/bus/pci/devices/$VF_ADDRESS"

        if [ -d "$VF_SYSFS" ]; then
          # 1. Unbind from i915
          if [ -d "$VF_SYSFS/driver" ]; then
            echo "$VF_ADDRESS" > "$VF_SYSFS/driver/unbind"
          fi

          # 2. Override the driver to vfio-pci
          echo "vfio-pci" > "$VF_SYSFS/driver_override"

          # 3. Bind to vfio-pci
          echo "$VF_ADDRESS" > /sys/bus/pci/drivers/vfio-pci/bind

          # 4. Clear the override
          echo "" > "$VF_SYSFS/driver_override"
        fi
      fi
    '';
  };
}
