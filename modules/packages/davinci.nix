{
  config,
  lib,
  pkgs,
  ...
}: let
  # DaVinci Resolve needs the NVIDIA dGPU — wrap it with the offload environment
  # variables so it always runs on the discrete GPU.
  davinci-resolve-wrapped = pkgs.symlinkJoin {
    name = "davinci-resolve-wrapped";
    paths = [pkgs.davinci-resolve];
    buildInputs = [pkgs.makeWrapper];

    postBuild = ''
      wrapProgram $out/bin/davinci-resolve \
        --set __NV_PRIME_RENDER_OFFLOAD 1 \
        --set __GLX_VENDOR_LIBRARY_NAME nvidia \
        --set CUDA_VISIBLE_DEVICES 0 \
        --set OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors/nvidia.icd
    '';
  };
in {
  environment.systemPackages = with pkgs; [
    davinci-resolve-wrapped
  ];
}
