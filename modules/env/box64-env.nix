{
  config,
  lib,
  pkgs,
  ...
}: let
  # ────────────────────────────────────────────────────────────────────────────
  # box64 FHS environment: run x86_64 (amd64) Linux binaries on this aarch64
  # host without a full distrobox/qemu container.
  #
  # How it works:
  # - box64 is an aarch64-native userspace translator (Dynarec). It executes
  #   x86_64 ELF binaries and maps their syscalls to the aarch64 kernel, but it
  #   does NOT provide x86_64 user libraries — the binary's NEEDED libraries
  #   (libc.so.6, libz, ...) must exist as real x86_64 files.
  # - buildFHSEnv lays out a single root: aarch64 tools (box64, bash, ...)
  #   live in the Nix store (patched absolute paths, unaffected), while the
  #   x86_64 library set from pkgsCross.gnu64 is copied into the Debian
  #   multiarch tree /lib/x86_64-linux-gnu inside the env.
  # - box64 is pointed at that tree via BOX64_LD_LIBRARY_PATH, so
  #   `box64 ./amd64-app` finds its libs at standard paths.
  # - Add more x86_64 packages to x86LibPkgs as needed (match the binary's
  #   dependency list, check with `readelf -d` / ldd-style analysis).
  # ────────────────────────────────────────────────────────────────────────────

  x86 = pkgs.pkgsCross.gnu64;

  x86LibPkgs = [
    x86.glibc
    x86.zlib
    x86.gcc-unwrapped.lib # libgcc_s
    x86.openssl
    x86.expat
    x86.libffi
    x86.ncurses
    x86.readline
    x86.sqlite
    x86.bzip2
    x86.xz
  ];

  box64-env-raw = pkgs.buildFHSEnv {
    name = "box64-env";
    targetPkgs = pkgs: (with pkgs; [
      box64
      bash
      coreutils
      findutils
      gnused
      gnugrep
      gawk
      procps
      file
      which
      gnutar
      gzip
      xz
      bzip2
      diffutils
    ]);

    extraBuildCommands = ''
      # x86_64 multiarch lib tree (Debian-style path) for box64 to load.
      # NOTE: $out/lib is a usrmerge symlink (-> /usr/lib -> /usr/lib64 on
      # aarch64), so create the tree under the real directory.
      mkdir -p $out/usr/lib64/x86_64-linux-gnu
      for d in ${lib.concatMapStringsSep " " (p: "${p}/lib") x86LibPkgs}; do
        if [ -d "$d" ]; then
          cp -a "$d"/. $out/usr/lib64/x86_64-linux-gnu/
          # cp -a preserves the source dir's (read-only) mode onto the
          # destination dir; restore write permission for the next copy.
          chmod -R u+w $out/usr/lib64/x86_64-linux-gnu
        fi
      done
    '';

    profile = ''
      export BOX64_LD_LIBRARY_PATH=/lib/x86_64-linux-gnu
      export BOX64_LOG=0
    '';
  };
in {
  environment.systemPackages = [box64-env-raw];
}
