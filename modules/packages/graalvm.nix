{inputs, ...}: {
  nixpkgs.overlays = [
    (final: prev: {
      graalvm-ce_21 = (import inputs.nixos-23-11 {
        system = prev.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      }).graalvm-ce;
    })
  ];
}
