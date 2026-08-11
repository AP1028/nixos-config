{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    (import ../../modules/services/comfyui.nix {
      inherit inputs lib pkgs;
      # Per-component GPU placement + layer distribution across the 2x 2080 Ti
      # (the built-in Select*Device nodes only create work-unit deepclones).
      customNodes = {
        ComfyUI-MultiGPU = pkgs.fetchFromGitHub {
          owner = "pollockjj";
          repo = "ComfyUI-MultiGPU";
          rev = "b51c99a525e9607e43545ee2a8b7694c74a4775a";
          hash = "sha256-Y3C4WgOtTyQ+S1mvSGd/2ypiUmuhdNGEKeMW/SPS2gI=";
        };
      };
    })
  ];
}
