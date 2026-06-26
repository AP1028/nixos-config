{inputs, ...}: {
  nixpkgs.overlays = [
    (final: prev: {
      graalvm-ce_21 = (import inputs.nixos-23-11 {
        localSystem = prev.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      }).graalvm-ce;
    })
  ];
}
