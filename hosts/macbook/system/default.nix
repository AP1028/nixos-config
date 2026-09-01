{
  pkgs,
  lib,
  ...
}: {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.11";

  # box64 0.4.4: newer than nixpkgs' 0.4.2 — DynaCache fixes, deferred signal
  # support, reworked Alt Address handling (relevant for the Cadence hang).
  #
  # fex 2608: newer than nixpkgs' 2605 (fixes a fmt-12 build break), plus the
  # 16K-pagesize jemalloc fix and a FEXInterpreter compat symlink (muvm's
  # guest looks for the old binary name). FEX only runs on 4K-page kernels,
  # so it is used inside the muvm microVM.
  nixpkgs.overlays = [
    (final: prev: {
      box64 = prev.box64.overrideAttrs (old: {
        version = "0.4.4";
        src = prev.fetchFromGitHub {
          owner = "ptitSeb";
          repo = "box64";
          tag = "v0.4.4";
          hash = "sha256-vcF3zYONE1P3DcXoo9PEETMDTA08QQi042SHt+hAT+Q=";
        };
      });

      fex = prev.fex.overrideAttrs (old: {
        version = "2608";
        src = prev.fetchFromGitHub {
          owner = "FEX-Emu";
          repo = "FEX";
          tag = "FEX-2608";
          hash = "sha256-2NdkQpzqDkM/fEW8QYS05KU3JPJeLw4gliryqdOJ3vE=";
          leaveDotGit = true;
          postFetch = old.src.postFetch or "";
        };
        patches = (old.patches or []) ++ [
          # Fix FEX JIT dropping the FS/GS segment base on vector memory stores
          # (MOVD/MOVQ/MOVNT*). Cadence's saSecurity/VSM TLS code uses
          # `%fs:-offset` SSE stores, which faulted because the FS base was
          # never added. See modules/env/fex-fs-segment-store-fix.patch.
          /home/tianyixia/nixos-config/modules/env/fex-fs-segment-store-fix.patch
        ];
        postPatch = (old.postPatch or "") + ''
          # This host runs a 16K-page kernel; jemalloc compiled with the
          # default LG_PAGE=12 (4K) refuses to run ("Unsupported system page
          # size").
          substituteInPlace External/jemalloc_glibc/pregen/include/jemalloc/internal/jemalloc_internal_defs.h \
            --replace-fail "#define LG_PAGE 12" "#define LG_PAGE 14"
        '';
        postInstall = (old.postInstall or "") + ''
          # muvm's guest looks for `FEXInterpreter` when setting up binfmt;
          # FEX 2608 renamed the interpreter binary to `FEX`.
          ln -sf FEX $out/bin/FEXInterpreter
        '';
      });
    })
  ];

  # Transparent x86_64 execution via box64 (needed by cadence-env: Cadence's
  # launchers are ksh scripts that exec x86_64 ELFs mid-chain — a native
  # script cannot run those without a kernel handler, and box64 cannot run
  # scripts itself).
  boot.binfmt.registrations.box64 = {
    interpreter = "${pkgs.box64}/bin/box64";
    recognitionType = "magic";
    offset = 0;
    magicOrExtension = "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00";
    mask = "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff";
  };
}
