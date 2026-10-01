{...}: {
  # ltrace 0.7.91's dejagnu suite has 15 unexpected failures in this
  # toolchain/sandbox (the derivation hash is unchanged from the previous
  # nixpkgs revision, so this predates the CUDA-driven bump). ltrace is only
  # used as a debugging tool inside the MATLAB FHS env
  # (modules/env/matlab-env.nix), where only the binary matters, so skip the
  # checks rather than carrying test-suite patches.
  nixpkgs.overlays = [
    (final: prev: {
      ltrace = prev.ltrace.overrideAttrs (_: {
        doCheck = false;
      });
    })
  ];
}
