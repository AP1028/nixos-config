# Overlay: make cardwire hide the NVIDIA *user-space manifests* from processes it
# blocks, not just the device nodes.
#
# Blocking /dev/nvidia* and the DRM nodes is not sufficient: the Vulkan ICD
# (`nvidia_icd.json`), the libglvnd EGL vendor (`10_nvidia.json`), the implicit
# layers and the OpenCL vendor file are ordinary readable files. A blocked
# process therefore still enumerates the NVIDIA driver, the driver loads, and
# then fails to open the denied device — and consumers that treat that as fatal
# instead of falling back (CEF/ANGLE/SwANGLE) crash-loop their GPU process and
# end up with GPU acceleration disabled and a window that appears 13-20 s late
# in software rendering. Measured: every `Disabled/CrashCount` event in the
# Steam client log dates from the day cardwire was installed; there are none
# before it.
#
# The patch (packages/patches/cardwire-hide-vendor-manifests.patch) adds
# `vendor_meta_inodes()` and appends those inodes to the *per-process* set
# (`core/inode.rs::get_inodes`), which `GpuInterface::sync_inodes` pushes into
# CW_BLOCKED_INO with the GPU id. Result: a blocked process sees no NVIDIA
# vendor at all (ENOENT on read, hidden from directory listings) while an
# allowed process keeps full access — including CUDA, which the *global*
# experimental block (CW_EXP_BLK_INO, upstream's `exp_nvidia_inodes`) cannot do.
final: prev: {
  cardwire = prev.cardwire.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./patches/cardwire-hide-vendor-manifests.patch ];
  });
}
