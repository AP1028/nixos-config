{...}: {
  nixpkgs.overlays = [(import ../../overlays/supergfxctl.nix)];
}
