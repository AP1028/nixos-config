# Reims vGPU — experimental paravirtual GPU for macOS guests (alpha upstream:
# the QEMU device ABI and boot scripts move without a compatibility promise).
#
# Upstream ships no packaging: `vm/boot-x86.sh` is meant to be run from a git
# clone and rebuilds both the vendored QEMU fork and the UEFI option ROM on
# every boot. This package turns those two *build* steps into pinned Nix
# derivations and leaves everything that is genuinely VM state (guest disk,
# OpenCore, OVMF vars, snapshot rails, logs) in a writable directory outside
# the store. See docs/reims-vgpu.md for the whole picture.
#
# What is here:
#   qemu        — the vendored QEMU fork with the `reims-vgpu-pci` device. The
#                 Rust device model (crates/reims-vgpu) is a staticlib linked
#                 into it, so the two cannot be split. Reproduces
#                 scripts/qemu-build/qemu-build.sh --target x86_64 --backend vulkan.
#   rom         — crates/reims-vgpu-efi built for x86_64-unknown-uefi and
#                 wrapped as a PCI option ROM; gives OVMF a framebuffer before
#                 macOS loads its own driver.
#   bootScript  — vm/boot-x86.sh with the two unconditional in-tree build
#                 steps removed, so the store's QEMU and ROM are used.
#   boot        — the user-facing `reims-vgpu-boot` wrapper: points the state
#                 directories at a writable VM tree and puts the shader
#                 toolchain on PATH.
{
  lib,
  pkgs,
  src,
  qemuSrc,
  rustOverlay,
}:
let
  version = "0.1.0-unstable-2026-09-03";

  # rust-overlay exists for exactly one thing nixpkgs cannot provide: the
  # x86_64-unknown-uefi std the option ROM builds against.
  pkgsRust = pkgs.extend (import rustOverlay);
  rustToolchain = pkgsRust.rust-bin.stable.latest.default.override {
    targets = [ "x86_64-unknown-uefi" ];
  };

  # QEMU's configure creates a venv and installs its vendored meson wheel into
  # it; mkvenv needs distlib/packaging (from the system, or pip's vendored
  # copies) to do that offline, and the "tooling" group wants
  # setuptools/wheel/pip visible so it does not reach for PyPI.
  pythonForQemu = pkgs.python3.withPackages (ps: [
    ps.distlib
    ps.packaging
    ps.setuptools
    ps.wheel
    ps.pip
  ]);

  # Cargo vendor for the host workspace (crates/*). The only git dependency is
  # metal2vulkan; the hash is the fetchgit hash of that revision.
  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = "${src}/Cargo.lock";
    outputHashes = {
      "metal2vulkan-0.1.0" = "sha256-T1JV283LCnfcztCAwceGM2UMoqcZWMuI7AIyvqa2fQw=";
    };
  };

  # The UEFI crate is its own workspace and upstream ships no Cargo.lock; the
  # lock next to this file was generated once and is copied into the tree.
  efiCargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = ./reims-vgpu-efi.Cargo.lock;
  };

  # QEMU's meson setup resolves three wrap-git subprojects that the sandbox
  # cannot download:
  #   keycodemapdb          — configure hard-fails without it.
  #   berkeley-softfloat-3  — pulled in through tests/fp, which is gated on
  #   berkeley-testfloat-3    TCG and therefore always configured.
  # The two float libraries also need QEMU's meson glue from
  # subprojects/packagefiles/ (what a wrap's patch_directory would overlay).
  keycodemapdb = pkgs.fetchgit {
    url = "https://gitlab.com/qemu-project/keycodemapdb.git";
    rev = "f5772a62ec52591ff6870b7e8ef32482371f22c6";
    hash = "sha256-EQrnBAXQhllbVCHpOsgREzYGncMUPEIoWFGnjo+hrH4=";
  };
  softfloat = pkgs.fetchgit {
    url = "https://gitlab.com/qemu-project/berkeley-softfloat-3.git";
    rev = "b64af41c3276f97f0e181920400ee056b9c88037";
    hash = "sha256-Yflpx+mjU8mD5biClNpdmon24EHg4aWBZszbOur5VEA=";
  };
  testfloat = pkgs.fetchgit {
    url = "https://gitlab.com/qemu-project/berkeley-testfloat-3.git";
    rev = "e7af9751d9f9fd3b47911f51a5cfd08af256a9ab";
    hash = "sha256-inQAeYlmuiRtZm37xK9ypBltCJ+ycyvIeIYZK8a+RYU=";
  };

  qemu = pkgs.stdenv.mkDerivation {
    pname = "qemu-reims-vgpu";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [
      rustToolchain
      pkgs.meson
      pkgs.ninja
      pkgs.pkg-config
      pythonForQemu
      pkgs.perl
      pkgs.flex
      pkgs.bison
      pkgs.makeWrapper
      # QEMU's meson install drops the build-tree rpath, so the store paths of
      # the linked libraries have to be patched back in after install.
      pkgs.autoPatchelfHook
    ];

    buildInputs = with pkgs; [
      glib
      pixman
      zlib
      libslirp
      dtc
      gtk3
      libepoxy
      libpng
      libjpeg
      zstd
      alsa-lib
      libpulseaudio
      pipewire
      wayland
    ];

    configurePhase = ''
      runHook preConfigure

      # Rebuild the layout the project's own build expects: the reims-vgpu
      # repo root with the QEMU fork at vendor/qemu (the fetched superproject's
      # gitlink is an empty directory).
      mkdir -p reims-vgpu/vendor/qemu
      cp -r --no-preserve=ownership ${src}/. reims-vgpu/
      chmod -R u+w reims-vgpu
      cp -r --no-preserve=ownership ${qemuSrc}/. reims-vgpu/vendor/qemu/
      chmod -R u+w reims-vgpu/vendor/qemu

      cp -r --no-preserve=ownership ${keycodemapdb}/. \
        reims-vgpu/vendor/qemu/subprojects/keycodemapdb/
      cp -r --no-preserve=ownership ${softfloat}/. \
        reims-vgpu/vendor/qemu/subprojects/berkeley-softfloat-3/
      cp -r --no-preserve=ownership ${testfloat}/. \
        reims-vgpu/vendor/qemu/subprojects/berkeley-testfloat-3/
      for p in berkeley-softfloat-3 berkeley-testfloat-3; do
        chmod -R u+w "reims-vgpu/vendor/qemu/subprojects/$p"
        cp -r --no-preserve=ownership \
          "reims-vgpu/vendor/qemu/subprojects/packagefiles/$p/." \
          "reims-vgpu/vendor/qemu/subprojects/$p/"
      done

      export CARGO_HOME="$TMPDIR/cargo-home"
      mkdir -p "$CARGO_HOME"
      cp "${cargoDeps}/.cargo/config.toml" "$CARGO_HOME/config.toml"
      substituteInPlace "$CARGO_HOME/config.toml" \
        --replace-fail 'directory = "cargo-vendor-dir"' "directory = \"${cargoDeps}\""
      export CARGO_NET_OFFLINE=true

      cd reims-vgpu/vendor/qemu
      ./configure \
        --target-list=x86_64-softmmu \
        --disable-hvf \
        --disable-cocoa \
        --disable-docs \
        --disable-bsd-user \
        --disable-linux-user \
        --disable-tools \
        --disable-download \
        --prefix=$out \
        -Dreims_vgpu_backend=vulkan \
        -Dblkio=disabled

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      cd "$NIX_BUILD_TOP/reims-vgpu/vendor/qemu"
      ninja -C build qemu-system-x86_64
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cd "$NIX_BUILD_TOP/reims-vgpu/vendor/qemu"
      ninja -C build install

      # The Rust staticlib dlopens the Vulkan loader, winit dlopens its
      # windowing libraries, and metal2vulkan spawns llvm-dis/spirv-val. None
      # of those are DT_NEEDED, so autoPatchelf cannot reach them.
      wrapProgram "$out/bin/qemu-system-x86_64" \
        --prefix PATH : "${lib.makeBinPath [
          pkgs.llvm
          pkgs.spirv-tools
        ]}" \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [
          pkgs.vulkan-loader
          pkgs.wayland
          pkgs.libxkbcommon
        ]}" \
        --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
      runHook postInstall
    '';

    meta = {
      description = "QEMU fork with the Reims vGPU paravirtual GPU device (Vulkan backend)";
      homepage = "https://github.com/steelbrain/reims-vgpu";
      license = lib.licenses.gpl2Plus;
      platforms = [ "x86_64-linux" ];
      maintainers = [ ];
    };
  };

  rom = pkgs.stdenv.mkDerivation {
    pname = "reims-vgpu-gop-rom";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [
      rustToolchain
      pkgs.python3
    ];

    buildPhase = ''
      runHook preBuild
      cp -r --no-preserve=ownership ${src} repo
      chmod -R u+w repo
      cp ${./reims-vgpu-efi.Cargo.lock} repo/crates/reims-vgpu-efi/Cargo.lock

      export CARGO_HOME="$TMPDIR/cargo-home"
      mkdir -p "$CARGO_HOME"
      cp "${efiCargoDeps}/.cargo/config.toml" "$CARGO_HOME/config.toml"
      substituteInPlace "$CARGO_HOME/config.toml" \
        --replace-fail 'directory = "cargo-vendor-dir"' "directory = \"${efiCargoDeps}\""
      export CARGO_NET_OFFLINE=true

      # The in-tree builder; its `rustup target add` is a no-op here because
      # the toolchain already carries the UEFI target. Invoked through bash:
      # the sandbox has no /usr/bin/env for its shebang.
      cd repo
      bash ./crates/reims-vgpu-efi/scripts/reims-vgpu-efi-rom/reims-vgpu-efi-rom.sh
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm444 "$NIX_BUILD_TOP/repo/crates/reims-vgpu-efi/out/reims-vgpu-gop.rom" \
        "$out/share/reims-vgpu/reims-vgpu-gop.rom"
      runHook postInstall
    '';

    meta = {
      description = "UEFI GOP option ROM for the Reims vGPU PCI device";
      homepage = "https://github.com/steelbrain/reims-vgpu";
      license = lib.licenses.lgpl3Plus;
      platforms = [ "x86_64-linux" ];
      maintainers = [ ];
    };
  };

  bootScript = pkgs.stdenv.mkDerivation {
    pname = "reims-vgpu-boot-x86";
    inherit version;
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 ${src}/vm/boot-x86.sh "$out/libexec/reims-vgpu/boot-x86.sh"

      substituteInPlace "$out/libexec/reims-vgpu/boot-x86.sh" \
        --replace-fail 'QEMU_BIN_DEFAULT="$REPO_ROOT/vendor/qemu/build/qemu-system-x86_64"' \
          "QEMU_BIN_DEFAULT=\"${qemu}/bin/qemu-system-x86_64\"" \
        --replace-fail 'if [ "$QEMU_BIN" = "$QEMU_BIN_DEFAULT" ]; then' \
          'if false; then' \
        --replace-fail '_reims_vgpu_gop_default="$REPO_ROOT/crates/reims-vgpu-efi/out/reims-vgpu-gop.rom"' \
          "_reims_vgpu_gop_default=\"${rom}/share/reims-vgpu/reims-vgpu-gop.rom\""

      # Skip the two unconditional in-tree build steps (QEMU is pinned above,
      # the ROM is a store path). Anchored so the function definitions, which
      # carry `() {`, stay intact.
      sed -i -e 's/^ensure_rust_tools$/:/' -e 's/^build_reims_vgpu_efi$/:/' \
        "$out/libexec/reims-vgpu/boot-x86.sh"

      runHook postInstall
    '';

    meta = {
      description = "Reims vGPU boot-x86.sh, repointed at store QEMU/ROM";
      homepage = "https://github.com/steelbrain/reims-vgpu";
      license = lib.licenses.lgpl3Plus;
      platforms = [ "x86_64-linux" ];
      maintainers = [ ];
    };
  };

  boot = pkgs.writeShellScriptBin "reims-vgpu-boot" ''
    set -euo pipefail

    # All mutable VM state: guest disk, OpenCore, OVMF vars, snapshot rails
    # and per-boot clones. Deliberately outside the nix store.
    VM_DIR="''${REIMS_VGPU_VM_DIR:-$HOME/reims-vgpu/vm}"
    export DISKS_DIR="''${DISKS_DIR:-$VM_DIR/disks}"
    export OVMF_DIR="''${OVMF_DIR:-$VM_DIR/ovmf}"
    mkdir -p "$DISKS_DIR" "$OVMF_DIR"

    # boot-x86.sh preflights these; metal2vulkan also spawns them per
    # uncached shader.
    export PATH="${lib.makeBinPath [
      pkgs.llvm
      pkgs.spirv-tools
    ]}:$PATH"

    exec ${bootScript}/libexec/reims-vgpu/boot-x86.sh "$@"
  '';
in
pkgs.symlinkJoin {
  name = "reims-vgpu-${version}";
  paths = [
    qemu
    rom
    bootScript
    boot
  ];
  passthru = {
    inherit
      qemu
      rom
      bootScript
      boot
      ;
  };
  meta = {
    description = "Reims vGPU: experimental paravirtual GPU for macOS guests (QEMU fork + GOP ROM + boot wrapper)";
    longDescription = ''
      Packages the host side of steelbrain/reims-vgpu: a QEMU fork carrying the
      reims-vgpu-pci device (Rust staticlib linked in, Vulkan backend) and the
      UEFI GOP option ROM, plus a `reims-vgpu-boot` wrapper around the
      project's vm/boot-x86.sh. Guest images are provisioned manually with
      OSX-KVM and live in a writable directory outside the store; see
      docs/reims-vgpu.md.
    '';
    homepage = "https://github.com/steelbrain/reims-vgpu";
    license = [
      lib.licenses.lgpl3Plus
      lib.licenses.gpl2Plus
    ];
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
