{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    # Same comfyui-nix setup as nixos-gpu-vm (shared module), but for the
    # RTX 5080 Mobile (Blackwell, sm_120).
    #
    # MiniMax H3 (omni-modal video, native stereo audio): needs ComfyUI
    # 0.30+ native nodes (merged upstream Aug 3 2026) — comfyui-nix pins
    # 0.30.2, so this is already covered.
    #
    # Model files staged at /var/lib/comfyui/models (hardlinked from
    # ~/Downloads, fp8_scaled variants preferred for Blackwell):
    #   diffusion_models/minimax_h3_{fl2va,ref2va}_pruned_fp8_scaled.safetensors
    #   text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
    #   vae/minimax_h3_{video_vae_fp16,audio_vae_fp32}.safetensors
    #
    # The int8_convrot variants (same size, older) stay in ~/Downloads as
    # fallback. 5080 Mobile has 16GB VRAM: pruned fp8/int8 are the only
    # viable diffusion variants; the 34GB int8 / 66GB bf16 will not fit.
    #
    # Service is intentionally DISABLED: the dGPU is still in use for gaming
    # (will be handed to VFIO later). Flip `enable = true` when the GPU
    # phase starts, then rebuild — the heavy comfy-ui-cuda closure build can
    # be pre-done any time with `nix build .#nixosConfigurations.asusg16.config
    # .system.build.comfyuiCuda` (8-core limited, does not touch the GPU).
    (import ../../modules/services/comfyui.nix {
      inherit inputs lib pkgs;
      enable = true;
    })
  ];
}
