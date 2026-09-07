# Build the x86_64 LD_PRELOAD interposer (for the FEX guest) from the aarch64
# host, via the nixpkgs gnu64 cross-toolchain.
let
  flake = builtins.getFlake "path:/home/tianyixia/nixos-config";
  pkgs = import flake.inputs.nixpkgs { };
  x86 = pkgs.pkgsCross.gnu64;
in
  x86.stdenv.mkDerivation {
    name = "qtimer-preload";
    src = flake.outPath + "/scripts/qtimer-preload";
    buildPhase = ''
      $CC -shared -fPIC -O2 -o qtimer_preload.so qtimer_preload.c -ldl -Wl,--version-script=qtimer.map
    '';
    installPhase = "mkdir -p $out; cp qtimer_preload.so $out/";
  }
