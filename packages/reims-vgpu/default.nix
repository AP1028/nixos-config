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

      # metal2vulkan scalar-into-aggregate device store: the native emitter
      # refused to reinterpret a scalar store through a pointer to an array or
      # struct unless the pointer lived in Function/Workgroup/Private storage,
      # so a device (StorageBuffer) store such as `store float` into a
      # `[10 x i32]` slot fell through to a raw OpStore whose pointee disagreed
      # with the value type, and the owned-module verifier refused the whole
      # kernel ("owned Store violates its pointer-pointee and value-type
      # contract") — Easy Red 2's skinning and blend-shape compute kernels.
      # The load and vector siblings of the same lowering already run in every
      # storage class, and the access chain plus value bitcast it emits is
      # valid SPIR-V in all of them, so the guard is dropped. Applied here
      # until it lands upstream. The vendor directory holds symlinks into the
      # store, so only metal2vulkan is copied for real; everything else keeps
      # pointing at its read-only store package.
      mkdir -p "$TMPDIR/cargo-vendor"
      cp -r --no-preserve=ownership "${cargoDeps}/." "$TMPDIR/cargo-vendor"
      rm -f "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0"
      cp -rL --no-preserve=ownership "${cargoDeps}/metal2vulkan-0.1.0" \
        "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0"
      chmod -R u+w "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0"
      patch -p1 -d "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0" \
        < ${./metal2vulkan-scalar-aggregate-store.patch}
      if grep -q 'StorageClass::Function | StorageClass::Workgroup | StorageClass::Private' \
           "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0/src/native/emitter/body/vector_store.rs"; then
        echo "metal2vulkan scalar-aggregate store guard survived the patch" >&2
        exit 1
      fi

      # metal2vulkan `[[base_vertex]]`/`[[base_instance]]`: the translator knew
      # neither role, so every vertex shader declaring one was refused at the
      # stage-input pass ("declares AIR role 'air.base_vertex', which has no
      # lowering") and every draw of a pipeline built from it was skipped --
      # Easy Red 2's scene pipelines, which is the black window. Metal's base
      # parameters are the values Vulkan's VertexIndex/InstanceIndex fold in
      # (so they cannot be recovered from those builtins), and are lowered to
      # the BaseVertex/BaseInstance builtins with the DrawParameters
      # capability and the SPV_KHR_shader_draw_parameters extension; the
      # matching shaderDrawParameters device feature is enabled by the engine
      # patch below. Applied here until it lands upstream.
      patch -p1 -d "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0" \
        < ${./metal2vulkan-base-vertex.patch}
      if ! grep -q 'VertRole::BaseVertex' \
           "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0/src/meta/mod.rs" \
         || ! grep -q 'SPV_KHR_shader_draw_parameters' \
           "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0/src/passes/stage_input/mod.rs"; then
        echo "metal2vulkan base-vertex lowering did not apply" >&2
        exit 1
      fi

      # metal2vulkan `[[front_facing]]` declared as an integer: Unity's HLSL
      # lowers some boolean uses to `i32`, and the stage-input pass refused the
      # parameter ("FrontFacing is a boolean builtin"), which dropped every
      # draw of each pipeline whose fragment shader did so -- the missing
      # vehicles in a driven Easy Red 2 scene. The builtin is loaded as the
      # bool it is and selected into the parameter's own integer type.
      patch -p1 -d "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0" \
        < ${./metal2vulkan-front-facing-int.patch}
      if ! grep -q 'LoadBoolSelect' \
           "$TMPDIR/cargo-vendor/metal2vulkan-0.1.0/src/passes/stage_input/mod.rs"; then
        echo "metal2vulkan front-facing lowering did not apply" >&2
        exit 1
      fi
      substituteInPlace "$CARGO_HOME/config.toml" \
        --replace-fail 'directory = "cargo-vendor-dir"' "directory = \"$TMPDIR/cargo-vendor\""
      export CARGO_NET_OFFLINE=true

      # PR #81 ("Fix format texel accounting in direct guest writeback"): the
      # compute direct-writeback path plans 4096-byte runs as 4-byte texels for
      # a 16-byte-per-texel R32G32B32A32_UINT image, so a copy overshoots its
      # region and writes GPU data into unrelated guest memory. This host's
      # failing boots produce exactly that image (1504x6016 R32G32B32A32_UINT,
      # 144769024 active bytes). Applied here until it lands upstream.
      patch -p1 -d reims-vgpu < ${./pr81.patch}

      # PR #79 ("settle queued guest writes before the guest takes its pages
      # back", stacked on PR #78's dependency-graph compaction): closes an
      # ordering hole where GPU writes through the host-pointer import land
      # after the guest has released the pages. Same defect class as #81.
      patch -p1 -d reims-vgpu < ${./pr79.patch}

      # Local: advertise two more panel timings (16:10 and 21:9) alongside the
      # stock 1920x1080 / 1440x1080 / 1280x1024 / 3840x2160 seed list. The
      # timing table is a plain array and the descriptor's count is written
      # dynamically, so the guest sees six modes.
      substituteInPlace reims-vgpu/crates/reims-vgpu/src/runtime/drain/mod.rs \
        --replace-fail '(DISPLAY_MODE3_W, DISPLAY_MODE3_H),' \
                       '(DISPLAY_MODE3_W, DISPLAY_MODE3_H), (2560, 1600), (3440, 1440),'

      # Fix for the Easy Red 2 black screen: Unity sets
      # maxTotalThreadsPerThreadgroup on its compute pipelines, and the decoder
      # refused the whole pipeline for the unidentified tag 0x08. The tag was
      # identified by driving Apple's own serializer (see the patch's doc).
      patch -p1 -d reims-vgpu < ${./pr-threadgroup.patch}

      # Fix for the remaining Easy Red 2 black screen: the Vulkan rail refused
      # a whole draw when a guest sampler bind could not be resolved, while the
      # macOS rail degrades to the binding's fallback and reports it. A driven
      # session measured 661 of 692 draws refused — 639 of them one full-screen
      # composite per frame — with the frame texture intact behind it, so the
      # drawable stayed at its black clear. Release the binding instead and let
      # the reflected-sampler loop provision the shader's own static sampler (or
      # the normalized default), keeping the refusal visible.
      patch -p1 -d reims-vgpu < ${./pr-sampler-fallback.patch}

      # Fix for the Easy Red 2 hang that survived the three above: the
      # CPU-visible compute path quiesced the whole device (`retire_all` —
      # flush the tail batch, wait every ring slot's fence up to 5s each, sweep
      # the graveyard) on the packet-processing thread, for every dispatch that
      # carries a readback. A driven session sat in it for minutes at a time
      # with the guest's packets queued behind, so the guest's Metal resource
      # deletes blocked in the kernel and Unity's render thread blocked behind
      # those — black screen with the device "alive". The wait a readback needs
      # is its own entry's fence; the periodic graveyard maintenance on the poll
      # heartbeat does the rest of the housekeeping without waiting.
      patch -p1 -d reims-vgpu < ${./pr-compute-retire-scope.patch}

      # Fix for the remaining black screen: a slot the guest has emptied and
      # re-created (a drawable ring recycles its refs every frame) makes the
      # draw that names it miss the object list, and refusing that draw is a
      # black frame — the composite that samples a re-created drawable is
      # exactly this shape, and the game's whole present path is behind it. The
      # slot-recheck module already measures these as publish races
      # (`slot_recheck_filled`); this latches the last resolution each ref
      # produced and serves it while the watch is young, so the frame is one
      # late instead of absent. Deferring the packet is the fuller answer the
      # module's doc names, and needs a dependency kind in the model; this is
      # the contained half.
      patch -p1 -d reims-vgpu < ${./pr-sampled-resolution-latch.patch}

      # The same publish race, on the blit path: a transient empty slot fails
      # the *upload* rather than a draw, so the game's textures never reach the
      # device and every draw that samples them comes out black — the black
      # window with music over it, while the desktop (whose textures resolved
      # cleanly) renders. Latches the last backing each (ref, level, slice)
      # resolved to and serves it while the watch is young.
      patch -p1 -d reims-vgpu < ${./pr-blit-texture-latch.patch}

      # The draw-target half of the same story: a render chain whose Store
      # skips its readback leaves the content on the device's resident with
      # nothing observable in the guest's pages — the import-present rail that
      # used to make it observable is gone (see `M2vDrawSpan::ResidentChain`'s
      # own note). The guest's WindowServer composites these windows by
      # sampling those pages, so the window is black over a running game. Arms
      # the surface writeback debt on that arm so the copy lands when the
      # pages are read.
      patch -p1 -d reims-vgpu < ${./pr-chain-resident-debt.patch}

      # The payment side of the same gap: the debt is armed by *mapping* and
      # paid by *texture ref* through `texture_to_mapping`, but only the
      # mapper-ref-texture resolution writes that latch — a linear texture
      # (which is what a drawable ring is) never did, so the payment resolved
      # nothing (`wbdebt_texture_owes_nothing_unresolved`) and the frame stayed
      # in the resident. Latches the ref -> mapping association for a linear
      # sample when exactly one mapping's page list holds the buffer's first
      # physical page.
      patch -p1 -d reims-vgpu < ${./pr-linear-sample-mapping-latch.patch}

      # The gather rail reads a mapping's pages and paid nothing first. The
      # zero-copy rails' own note states the rule ("the payment is what puts it
      # on the queue; then queue order applies") and this rail was the
      # exception: a debt-owed frame has no command on any queue, so the
      # gather read the pages the frame before last. That is the black window
      # over a running game, and it is the rail the failing games' samples take
      # (`sampled_direct_declined` sends them here).
      patch -p1 -d reims-vgpu < ${./pr-gather-pays-writeback-debt.patch}

      # The black game window, root cause: Unity encodes render passes with
      # `MTLStoreActionUnknown` (the SDK's deferred form) and replaces it with a
      # `SetStoreAction` record before ending the encoder. The model's descriptor
      # resolver refused the unknown ordinal, so the ordering plane refused the
      # *whole exec packet* — a driven Unity title lost 84 % of its render
      # packets (2 600-3 000 a second refused against 2 900 loaded, all
      # `field: "store_action", value: 4`) and the window stayed at its black
      # clear while music and UI kept running. Accepts the deferred ordinal as
      # the preserving answer, and applies each stream's own `SetStoreAction`
      # overrides to the model's descriptor so the dependency graph's
      # resolve-target edge follows the action the guest actually chose.
      patch -p1 -d reims-vgpu < ${./pr-store-action-deferred.patch}

      # The vertex half of the same window: with the store-action packets
      # admitted, every draw of the game's scene pipelines was then refused by
      # the stage-input pass, because the vertex shaders declare Metal's
      # `[[base_vertex]]`/`[[base_instance]]` and the translator had no
      # lowering for either role (27 708 refusals, all non-indexed 3-vertex
      # draws). The metal2vulkan patch above emits the Vulkan
      # BaseVertex/BaseInstance builtins; this enables the `shaderDrawParameters`
      # device feature those builtins require. Chained only when the host
      # reports the feature, so a host without it still gets a device (and
      # still refuses to promise a base it cannot read).
      patch -p1 -d reims-vgpu < ${./pr-shader-draw-parameters.patch}

      # The four render-target formats a driven Unity title declares and this
      # device refused as `rt_resolve reason=rt_linear_format`, each admitted
      # with its full rail set (render target, sampled bind, byte copy, CPU
      # conversion, and the cross-check that holds those tables together):
      # `RG11B10Float` (HDR scene colour), `RGB10A2Unorm` (its packed sibling),
      # `R16Unorm` (a single-channel target), and `RGBA8Snorm` (the normal /
      # velocity buffer). Every Vulkan spelling is the guest's own word.
      patch -p1 -d reims-vgpu < ${./pr-render-target-formats.patch}

      # The sampled bind of the depth buffer: a depth attachment is keyed by the
      # guest's texture reference (it is the one target kind whose content has
      # no CPU copy anywhere), and the GVA rails cannot name it. Binds the
      # texture-keyed resident and, for a depth image, takes the resident's own
      # format and aspects, since the bind's spelling may name another depth
      # precision.
      patch -p1 -d reims-vgpu < ${./pr-depth-resident-sample.patch}

      # An MSAA pass that stores with `StoreAndMultisampleResolve` and a
      # continuing record that LOADs the multisample scratch: both were refused,
      # which lost the geometry of every such pass. The multisample image is
      # device scratch (no rail writes one back to guest pages), so the resolve
      # is the whole observable effect of the store action.
      patch -p1 -d reims-vgpu < ${./pr-msaa-store-and-resolve.patch}

      # The other half of a depth bind: the guest ping-pongs its camera depth
      # and samples the half the render pass did not name, so the bind's own
      # identity finds no resident even though the frame this device just
      # rendered is exactly what it asked for. Serves the most recent ready
      # depth resident of the same geometry, excluding the draw's own depth
      # attachment (serving that is a feedback read the engine answers with a
      # full-image snapshot per draw).
      patch -p1 -d reims-vgpu < ${./pr-depth-resident-latest.patch}

      # A depth sample no rail can serve is a composite/post pass whose whole
      # purpose is to put the 3D layer on screen; refusing it costs the guest
      # the frame. Serves a 1x1 neutral (reading far, the value the guest's own
      # clear left) and keeps the loss on the fail channel.
      patch -p1 -d reims-vgpu < ${./pr-depth-neutral-fallback.patch}

      # The same guest allocation can be described by two task-local texture
      # objects (a render thread renders into its own reference while another
      # task samples the same storage), and the writeback ledger keys by
      # `(task, reference)`. Answers a sampled bind's lookup by allocation so
      # the resident holding the frame is found under the other name.
      patch -p1 -d reims-vgpu < ${./pr-gva-debt-by-allocation.patch}

      # A chain resident for a GVA target (the game's own render target) armed
      # no writeback debt at all: `arm_surface_writeback_debt` is mapping-keyed
      # and refuses `mid=0`, so a later pass that sampled the target gathered
      # pages nothing ever wrote and the scene composited black.
      patch -p1 -d reims-vgpu < ${./pr-chain-gva-writeback-debt.patch}

      # The completion side: the `Queued` publication arms hand a stamp word to
      # the GPU-ordered rail and return, so the page is only written if that
      # queued write is not superseded first. When it is, a guest waiting on
      # the slot waits forever (the render thread stalled in a resource
      # deallocation for minutes). Re-issues the ordered write on a later pass
      # when the page has not caught up — ordered, not inline: an inline write
      # fires the guest's fence before the work it completes, which a driven
      # session measured as red corruption across the guest's desktop.
      patch -p1 -d reims-vgpu < ${./pr-stamp-page-reissue.patch}


      # DIAGNOSTIC (temporary): one line a second naming every stamp slot's
      # guest-visible page word against the ordering plane's held point and any
      # queued word still owed a landing, plus the positions this device holds
      # and the stamps they watch. Remove once the black-window stall is fixed.
      patch -p1 -d reims-vgpu < ${./pr-diag-stamp-census.patch}


      # DIAGNOSTIC (temporary, opt-in via REIMS_VGPU_DIAG_CHAIN_READBACK=1):
      # names the depth identity the render side keys a resident under and the
      # candidates a sampled bind asks about, and can force a chain resident to
      # be read back so its rendered content is observable. Remove once the
      # depth rails no longer need reading.
      patch -p1 -d reims-vgpu < ${./pr-diag-sampled-depth.patch}

      # Assessment fixes (see docs/reims-vgpu-code-assessment.md): the five
      # `resolve_sampled_source` test call sites `pr-depth-resident-latest`
      # left behind (the crate's test target did not compile), the dead
      # `page_entries` comparison in the linear-sample mapping latch, the
      # `Settled`-answer drop in the stamp re-issue, the block-aligned
      # texture-to-texture bounds check (compressed mip tails), the deferred
      # store ordinal on the contract/publish predicates, the lossy marking the
      # two packed HDR layouts never got, the `depth_resident_latest` fail line,
      # and the `unorm8_to_snorm_byte` doc correction.
      patch -p1 -d reims-vgpu < ${./pr-assessment-fixes.patch}

      # Star Birds' black window: the compositor reads a mapping's guest pages
      # (the gather rail pays `pay_for_mapping`), while the game's frames are
      # deferred into residents armed as GVA-keyed debts keyed by `(task, ref)`.
      # A mapping-keyed lookup cannot see those, so the payment found nothing
      # and the gather read pages the render never wrote
      # (`wbdebt_texture_owes_nothing_unresolved`, and every `diag_sample_probe`
      # answering `debt=None`). Aliasing across the id namespaces is real, so a
      # mapping that owes nothing while GVA debts exist settles the ledger —
      # the `pay_all` doctrine the module already states for "cannot name"
      # readers. Counted as `wbdebt_mapping_pays_gva_alias` so the cost and the
      # frequency of the real alias are both visible.
      patch -p1 -d reims-vgpu < ${./pr-starbirds-mapping-gva-alias.patch}

      # DIAGNOSTIC (temporary, opt-in via REIMS_VGPU_PRESENT_DUMP=<dir>): write
      # the resident the host window is about to present as a P6 PPM, so the
      # frame the device actually rendered can be looked at directly instead of
      # being inferred from counters. Remove once the black window is fixed.
      patch -p1 -d reims-vgpu < ${./pr-diag-present-dump.patch}

      # Star Birds' black window, root cause: the game's scene intermediate is
      # `MTLPixelFormatRG32Float` (MTL 0x69), which this device had no rail for
      # at all. The scene pass was refused as a render target
      # (`rt_resolve reason=rt_linear_format`) and the full-screen composite that
      # samples it was refused as a bind (`reason=linear_sample`), so the game's
      # window never received the scene and WindowServer composited an empty
      # (black) window onto the display surface the device then presented.
      #
      # Admitted the way the four Easy Red 2 formats are: a `TexelLayout::Rg32Float`
      # (8 bytes/texel, float class, no CPU arm — the `R32Float` precedent, since
      # the native copy is the guest's own word), a `SampledClass::Rg32Float` with
      # the sampled/linear maps against `R32G32_SFLOAT`, the render-target
      # admission with `store_texel_order` for the byte copy, and the
      # sampled-image-only compute class. The capability snapshot's dimension
      # field narrows from 32 bits to 16 to make room for the new layout bit: the
      # masks are exactly what their readers ask about, and a Vulkan image
      # dimension needs sixteen bits, not thirty-two.
      patch -p1 -d reims-vgpu < ${./pr-rg32float.patch}

      # The remaining Star Birds pass class: full-screen MSAA resolve records
      # whose *first* record declares `Load` (`multisample_load_action_unsupported`,
      # four a boot, 3- and 6-vertex draws into 1920x1080 targets). The engine
      # keeps one multisample scratch per key and reuses it while the key
      # matches, so a first-in-packet record can be honouring a load the packet
      # boundary merely hides — but a *fresh* image cannot: it is created with
      # `UNDEFINED` contents. The pass's load op is therefore chosen from the
      # slot's own liveness, at the one place the key exists (the resolve and
      # depth views it names are resolved above where the pass is first picked):
      # a live slot keeps the load, a fresh one begins with a clear, and the
      # runtime stops refusing the record. `multisample_slot_is_live` is the one
      # predicate both the acquisition and this choice use, so they cannot drift.
      patch -p1 -d reims-vgpu < ${./pr-msaa-fresh-slot-load.patch}




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

      # Local addition: `--persistent`. The harness is snapshot-revert by
      # design (--testing/--interactive discard their clone, --capture only
      # persists on a clean shutdown), which loses a session when the guest
      # crashes on the way out. --persistent boots the provisioned masters in
      # vm/disks + vm/ovmf write-through instead: every change lands on the
      # disk as it happens, nothing is promoted or discarded.
      substituteInPlace "$out/libexec/reims-vgpu/boot-x86.sh" \
        --replace-fail '    --capture) BOOT_CLASS="capture"; shift ;;' \
          '    --capture) BOOT_CLASS="capture"; shift ;;
    --persistent) BOOT_CLASS="persistent"; shift ;;' \
        --replace-fail '  [ "$BOOT_CLASS" = "capture" ] || die \' \
          '  [ "$BOOT_CLASS" = "capture" ] || [ "$BOOT_CLASS" = "persistent" ] || die \' \
        --replace-fail '  HAVE_SNAPSHOT=1
fi' '  HAVE_SNAPSHOT=1
fi
# --persistent ignores rails and snapshots entirely: the masters ARE the disk.
if [ "$BOOT_CLASS" = "persistent" ]; then
  HAVE_SNAPSHOT=0
fi' \
        --replace-fail 'if [ "$BOOT_CLASS" = "interactive" ] || [ "$BOOT_CLASS" = "capture" ]; then' \
          'if [ "$BOOT_CLASS" = "interactive" ] || [ "$BOOT_CLASS" = "capture" ] || [ "$BOOT_CLASS" = "persistent" ]; then' \
        --replace-fail '    [ "$BOOT_CLASS" = "capture" ] && echo "boot-x86.sh: qemu exited rc=$rc (not clean) — snapshot NOT updated"' \
          '    [ "$BOOT_CLASS" = "capture" ] && echo "boot-x86.sh: qemu exited rc=$rc (not clean) — snapshot NOT updated"
    [ "$BOOT_CLASS" = "persistent" ] && echo "boot-x86.sh: persistent boot exited rc=$rc — masters left in place"'

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

    # Host-pointer imports stay on: PR #81 + #79 (patched into the build above)
    # fix the guest panic this host hit on ~60% of boots, and imports are the
    # fast rail (the copying fallback measured ~1.8 Hz against ~30 Hz here).
    # REIMS_VGPU_GUEST_IMPORT=off remains available as a fallback.

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
