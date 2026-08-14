{lib, ...}: {
  options.local.nvidiaGridLib = lib.mkOption {
    type = lib.types.str;
    description = "NVIDIA vGPU guest userspace lib dir (for CUDA binary rpaths)";
  };
}
