{...}: {
  # riscv-pk's configure.ac hardcodes "-Wall -Werror" into CFLAGS. GCC 16
  # (this nixpkgs) emits a false-positive -Wmaybe-uninitialized for
  # machine/emulation.c's emulate_system_opcode, so the build dies before
  # spike's install check (which needs pkgsCross.riscv64-embedded.riscv-pk
  # as its proxy kernel) can run. Drop -Werror; the patch targets
  # configure.ac because autoreconfHook regenerates configure from it.
  nixpkgs.overlays = [
    (final: prev: {
      pkgsCross = prev.pkgsCross // {
        riscv64-embedded = prev.pkgsCross.riscv64-embedded // {
          riscv-pk = prev.pkgsCross.riscv64-embedded.riscv-pk.overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                substituteInPlace configure.ac \
                  --replace-fail '-Wall -Werror' '-Wall'
              '';
          });
        };
      };
    })
  ];
}
