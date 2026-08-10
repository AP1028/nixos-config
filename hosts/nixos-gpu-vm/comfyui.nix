{
  inputs,
  ...
}: {
  imports = [
    inputs.comfyui-nix.nixosModules.default
  ];

  nixpkgs.overlays = [
    inputs.comfyui-nix.overlays.default
  ];

  services.comfyui = {
    enable = true;
    # NVIDIA CUDA support via pre-built PyTorch CUDA wheels (Pascal..Blackwell).
    gpuSupport = "cuda";
    listenAddress = "0.0.0.0";
    port = 8188;
    # Models live under /var/lib/comfyui/models/{diffusion_models,text_encoders,vae}
    dataDir = "/var/lib/comfyui";
    openFirewall = true;
  };
}
