{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # Vendor offload variables (libglvnd / Vulkan loader): these are what make a
  # process actually *pick* the NVIDIA GPU while the iGPU stays visible and
  # keeps handling presentation (Xwayland DRI3/Present is backed by the iGPU —
  # KWin's render node — so hiding the iGPU breaks CEF and Proton games).
  vendorEnv = {
    __NV_PRIME_RENDER_OFFLOAD = "1";
    __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    __VK_LAYER_NV_optimus = "NVIDIA_only";
    VK_LOADER_DRIVERS_SELECT = "*nvidia*,*nouveau*";

    # nvidia.nix no longer pins the EGL vendor list globally (see the comment
    # there), so offloaded EGL clients select NVIDIA explicitly.
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
  };

  # Cardwire only ever switches between "iGPU only" (Blocked) and "both GPUs
  # available" (Allowed); CARDWIRE_FORCE_DGPU is deliberately NOT used anywhere,
  # because it hides the iGPU and that breaks any windowed client on a
  # Wayland+Xwayland session (measured: Steam's CEF GPU process crash-loops,
  # Proton games die on swapchain creation).
  dgpuEnv = vendorEnv // {
    CARDWIRE_ALLOW = "1";
  };

  exportsOf = env: lib.concatLines (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") env
  );

  dgpuExports = exportsOf dgpuEnv;

  # The frozen nixpkgs snapshot the cardwire package is built from (flake.nix).
  # Imported once here so both the package and the GUI shim below share it.
  cardwireNixpkgs = import inputs.nixpkgs-cardwire.outPath {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = config.nixpkgs.config or { };
  };

  # Same library path the package's stock cardwire-gui wrapper sets
  # (wayland, libxkbcommon, vulkan-loader, libglvnd).
  cardwireGuiLibPath = cardwireNixpkgs.lib.makeLibraryPath (with cardwireNixpkgs; [
    wayland
    libxkbcommon
    vulkan-loader
    libglvnd
  ]);

  # cardwire is built from the pinned nixpkgs (glibc 2.42), but
  # /run/opengl-driver — where cardwire-gui picks up Mesa/EGL — comes from the
  # *system* nixpkgs (glibc 2.44, Mesa 26.2.3). Mesa's libgallium requires
  # GLIBC_2.43+, so inside the pinned-glibc process glvnd's dlopen of
  # libEGL_mesa.so.0 fails and the Mesa EGL vendor is silently dropped; NVIDIA's
  # EGL vendor then fails too and glvnd returns EGL_NO_DISPLAY *without* setting
  # an EGL error, which makes khronos-egl panic during wgpu's Instance::new.
  # Run the real GUI binary through the system loader instead — the pinned
  # binary itself is forward compatible — while keeping the pinned runtime
  # libraries exactly like the stock wrapper did.
  cardwireGuiShim = pkgs.writeShellScriptBin "cardwire-gui" ''
    exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
      --library-path ${lib.escapeShellArg (lib.concatStringsSep ":" [
        "${pkgs.glibc}/lib"
        cardwireGuiLibPath
      ])} \
      ${config.services.cardwired.package}/bin/.cardwire-gui-wrapped "$@"
  '';
in {
  # Cardwire installs eBPF LSM hooks that make the blocked GPU's device nodes
  # (/dev/dri/renderD*, /dev/nvidia*, nvidia modeset/uvm, GPU sysfs attributes)
  # return -ENOENT to every process that has not been explicitly allowed. This
  # is what replaces the per-application bwrap / GLX / EGL / Vulkan-ICD
  # workarounds: a blocked GPU cannot be woken by Vulkan ICD enumeration, an
  # Electron renderer, a GTK app or nvtop, no matter how it is packaged.
  #
  # Smart mode is inverted by cardwire-blacklist-mode.patch (2026-09-28): the
  # dGPU is ALLOWED by default and only applications with an explicit Blocked
  # row are denied. Only two states exist here — "iGPU only" and "both GPUs" —
  # never "iGPU hidden":
  #   - KDE's "Launch using Discrete Graphics Card" (Switcheroo D-Bus shim)
  #   - `nvidia-offload` (CARDWIRE_ALLOW=1 + PRIME vendor vars)
  #   - the per-application list in cardwire-gui (only rows flipped to Blocked
  #     deny; Allowed rows are just the default)
  #
  # Known gaps, measurement evidence and what is still untested are documented
  # in the "ROBUSTNESS NOTES" block at the end of this file — read that before
  # adding another workaround for a GPU problem.
  services.cardwired = {
    enable = true;
    settings = {
      auto_apply_gpu_state = true;
      # Deliberately OFF, despite upstream recommending it. With it on,
      # cardwire unlinks /dev/nvidiactl and /dev/nvidia0 globally, so CUDA is
      # unavailable in smart mode even for approved processes (measured:
      # nvidia-offload nvidia-smi and cuInit both fail, only the GL/Vulkan
      # render-node path survives). With it off, measured behaviour is:
      #   blocked process  -> cuInit = 100 (CUDA_ERROR_NO_DEVICE), no wake-up
      #   approved process -> cuInit = 0, GPU wakes to D0 as intended
      #   idle             -> back to D3cold within ~15s either way
      experimental_nvidia_block = false;
      # OFF deliberately. battery_auto_switch is the ONE path into apply_mode
      # that does not check whether the target GPU drives the display: on a
      # battery event it unconditionally requests Modes::Integrated, whose loop
      # calls block_gpu() without the is_gpu_active() probe that the Manual-mode
      # set_block D-Bus path has (battery_switch.rs -> apply_mode). The only
      # thing standing between that and a black screen is the
      # `system_type != SystemType::Laptop` rejection, which is a topology
      # accident rather than a design guard. With the MUX flipped to
      # dGPU/Discrete the dGPU is boot_vga and drives the panel, so this is off.
      battery_auto_switch = false;
      # This chassis wires HDMI to the NVIDIA GPU (card0-HDMI-A-2); without
      # this, a blocked dGPU means no external output on that port. While a
      # dGPU-attached display is plugged in, Cardwire temporarily falls back to
      # hybrid mode (docked = on AC, so the battery cost is moot).
      external_display_auto_switch = true;
    };
  };

  # Powerd must keep running: it is what makes NVIDIA Dynamic Boost work on
  # this laptop. cardwire, however, stops nvidia-powerd every time it enters a
  # blocking mode (integrated/smart) and restarts it on the way back to hybrid
  # (crates/cardwire-daemon/src/interface/mode.rs) — the restart then races the
  # GPU wake-up and the daemon ends up failed. There is no cardwire config knob
  # for this (the config struct is exactly the settings submodule's keys), but it
  # only touches the service when `systemctl is-enabled nvidia-powerd.service`
  # contains "enabled" (core/gpu/nvidia.rs). So drop the [Install] symlink and
  # pull the unit in from a dependency instead:
  #   - powerd still starts at boot (via the oneshot below)
  #   - `systemctl start/stop nvidia-powerd` in gpu-power-scripts /
  #     gpu-vfio-scripts keeps working (a "static" unit can be started by hand)
  #   - cardwire sees is-enabled = "static" and leaves it alone entirely
  # RefuseManualStop would have been one line, but it would break those scripts.
  systemd.services.nvidia-powerd.wantedBy = lib.mkForce [];
  systemd.services.nvidia-powerd-boot = {
    description = "Pull in nvidia-powerd without marking it enabled";
    wantedBy = ["multi-user.target"];
    wants = ["nvidia-powerd.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${pkgs.coreutils}/bin/true";
  };

  # Cardwire persists the active mode and re-applies it in pre_daemon_tasks, so
  # this only has to cover the first boot (and any persisted Integrated/Smart).
  # It is NOT sufficient on a dGPU/Discrete MUX: the dGPU is then the primary
  # display, cardwire classifies the system as Manual or Desktop, and
  # `set smart` returns fdo::Error::NotSupported — the unit exits 1 and the
  # persisted mode stands. See "ROBUSTNESS NOTES" for what to replace this with.
  systemd.services.cardwire-set-smart = {
    description = "Set Cardwire GPU mode to smart";
    wantedBy = ["multi-user.target"];
    after = ["cardwired.service"];
    requires = ["cardwired.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${lib.getExe' config.services.cardwired.package "cardwire"} set smart";
  };

  # ── Cardwire itself is pinned ────────────────────────────────────────
  # The package and its whole build environment (rustPlatform, bpf-linker, aya
  # from the pinned Cargo.lock) come from the frozen nixpkgs snapshot in flake.nix
  # — the `nixpkgs-cardwire` input, currently d6524aaca2ff07876657ae2b323f24be4874944b
  # — and NOT from the moving `nixpkgs` input. `nix flake update` therefore cannot
  # move cardwire, its dependencies or its upstream version under us. Bump that
  # input deliberately, then re-test the Steam client, a desktop-entry launch and
  # a game on the dGPU.
  #
  # The five local patches (packages/patches/) are applied on top; the
  # measurements behind each one are in "ROBUSTNESS NOTES" at the end of this
  # file:
  # ORDER MATTERS: four of them patch analyzer/models.rs, so they are applied in
  # the order below (verified against pristine v0.12.1 in that order). Reordering
  # or dropping one can make the next fail to apply.
  #
  #   cardwire-hide-nvidia-userspace      blocked processes cannot read the NVIDIA
  #                                       manifests *or* load its driver libraries,
  #                                       so an injected vendor variable is inert
  #   cardwire-never-hide-igpu            FORCE_* never hide the iGPU; launcher
  #                                       requests are advisory; Steam's runtime
  #                                       helpers are always allowed; the CEF host
  #                                       is excluded from request grants
  #   cardwire-rescan-running-processes   re-evaluate /proc at daemon start, so a
  #                                       restart cannot strand a running game
  #   cardwire-steam-discovery            resolve steam_app_<id> before the XDG
  #                                       heuristics, so a new game gets its row
  #   cardwire-blacklist-mode             invert Smart mode: allow the dGPU by
  #                                       default, deny only explicit Blocked rows
  #                                       (steamwebhelper is denied by name), and
  #                                       discover apps as Allowed rows
  services.cardwired.package = let
    # Content-addressed, so editing anything else in this repository does not
    # change the patch store paths — and therefore does not force a cardwire
    # recompile on the next rebuild.
    patch = name:
      builtins.path {
        path = ../../packages/patches/${name}.patch;
        name = "${name}.patch";
      };
  in
    cardwireNixpkgs.cardwire.overrideAttrs (old: {
      patches =
        (old.patches or [])
        ++ [
          (patch "cardwire-hide-nvidia-userspace")
          (patch "cardwire-never-hide-igpu")
          (patch "cardwire-rescan-running-processes")
          (patch "cardwire-steam-discovery")
          (patch "cardwire-blacklist-mode")
        ];
    });

  # ── The blacklist: what must not touch the dGPU ──────────────────────
  # With Smart mode inverted (cardwire-blacklist-mode.patch) these rows are the
  # entire policy: every application without a Blocked row — including every
  # Steam game — is allowed by default and needs no flipping in cardwire-gui.
  # No library scanning, no file watcher, no restart machinery: the watcher that
  # re-seeded on every Steam write was restarted 13 times in an hour and
  # silently demoted a running game to the iGPU (see "ROBUSTNESS NOTES" at the
  # end of this file for the measurement).
  #
  # The Steam client and its CEF host must be Blocked. CEF/ANGLE cannot drive
  # the NVIDIA stack (measured: no window at all), and steam.desktop sets
  # PrefersNonDefaultGPU=true, so KDE asks cardwire to launch the client on the
  # dGPU; the launcher request is advisory and these Blocks are what make it
  # lose. steamwebhelper is *also* denied by name in the analyzer
  # (cardwire-blacklist-mode.patch), so it stays on the iGPU even if its row is
  # flipped in the GUI — the row is seeded so the app is visible there. Existing
  # choices are kept (ON CONFLICT DO NOTHING), so flipping a row in
  # cardwire-gui sticks. Relaunch an app after flipping it — a process keeps the
  # decision it got at exec.
  #
  # Games need no rows: a game is discovered as Allowed on first launch and runs
  # on the dGPU immediately. Add anything else that must stay on the iGPU here
  # (`binary_name` is the process comm, e.g. `ps -o comm= -p <pid>`), or flip
  # its discovered row to Blocked in cardwire-gui.
  systemd.services.cardwire-steam-client-policy = {
    description = "Keep the Steam client and its CEF host blocked in cardwire";
    wantedBy = ["multi-user.target"];
    before = ["cardwired.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    path = [pkgs.sqlite pkgs.coreutils];
    script = ''
      set -euo pipefail
      db=/var/lib/cardwire/cardwire.db
      install -d -m 0755 /var/lib/cardwire

      # Same schema the daemon creates, so a fresh state directory works too.
      sqlite3 "$db" <<'SQL'
      CREATE TABLE IF NOT EXISTS app_policies (
          binary_name TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          desktop_file_id TEXT,
          icon_name TEXT,
          policy INTEGER NOT NULL DEFAULT 0
      );
      SQL

      sqlite3 "$db" "INSERT INTO app_policies (binary_name, display_name, desktop_file_id, icon_name, policy)
                     VALUES ('steam', 'Steam', NULL, 'steam', 0)
                     ON CONFLICT(binary_name) DO NOTHING;"
      sqlite3 "$db" "INSERT INTO app_policies (binary_name, display_name, desktop_file_id, icon_name, policy)
                     VALUES ('steamwebhelper', 'Steam CEF Host', NULL, 'steam', 0)
                     ON CONFLICT(binary_name) DO NOTHING;"
    '';
  };

  environment.systemPackages = [
    # Replaces the stock nvidia-offload script (disabled in nvidia.nix): the
    # same PRIME vendor variables plus CARDWIRE_ALLOW=1, without which the LSM
    # hook keeps /dev/nvidia* blocked. Note ALLOW, not FORCE: both GPUs stay
    # visible so windows can be presented, while the vendor vars make the
    # process actually render on the dGPU. How CUDA/CLI work reaches the dGPU:
    # `nvidia-offload python train.py`.
    (pkgs.writeShellScriptBin "nvidia-offload" ''
      ${dgpuExports}
      exec "$@"
    '')

    # nvtop opens /dev/nvidiactl unconditionally. In blacklist mode it would be
    # allowed anyway, but the explicit grant keeps it working if the mode is ever
    # flipped back to a whitelist build.
    (lib.hiPrio (pkgs.writeShellScriptBin "nvtop" ''
      export CARDWIRE_ALLOW=1
      exec ${pkgs.nvtopPackages.nvidia}/bin/nvtop "$@"
    ''))

    # cardwire-gui must run under the system glibc, not the pinned one (see
    # cardwireGuiShim above); hiPrio makes it win over the package's binary,
    # including for the Exec=cardwire-gui line in the desktop file.
    (lib.hiPrio cardwireGuiShim)

    # No Steam launcher and no per-game launch options: under the blacklist every
    # game is Allowed by default and picks the GPU itself on first launch. Only
    # the Steam client and its CEF host stay Blocked/iGPU, so the client never
    # hands CEF a NVIDIA stack it cannot drive.
  ];

  # ─────────────────────────────────────────────────────────────────────────
  # ROBUSTNESS NOTES — what is guaranteed, what is not, and what is untested.
  #
  # The model (enforced by packages/patches/*.patch on the pinned package):
  #   * BLACKLIST (2026-09-28, cardwire-blacklist-mode.patch). The default is
  #     ALLOW: an application is denied the dGPU only when it has an explicit
  #     Blocked row. `steam` and `steamwebhelper` are seeded Blocked; everything
  #     else — games, nvtop, nvidia-smi, Bottles/Lutris/Heroic titles — reaches
  #     the dGPU with no per-app flipping. The LSM machinery is unchanged: the
  #     analyzer inserts every non-blocked process into the eBPF allow map (so
  #     Blacklist is still per-process, and the iGPU-only state still exists for
  #     blacklisted apps), and steamwebhelper is denied by name *before* its
  #     inherited SteamAppId could resolve to an Allowed row. Discovery now
  #     creates Allowed rows, purely so cardwire-gui has something to flip to
  #     Blocked.
  #   * Only two states exist: Blocked (iGPU only) and Allowed (both GPUs).
  #     The iGPU is never hidden — hiding it breaks Xwayland presentation and
  #     kills CEF's GPU process and Proton's swapchain creation.
  #   * Blocked hides the dGPU's device nodes *and* the NVIDIA user-space
  #     manifests (Vulkan ICD, EGL/GLX vendor, implicit layers, OpenCL) from that
  #     process only, so a denied app falls back to Mesa instead of enumerating a
  #     driver it cannot open (that enumeration failure is what crash-looped
  #     Steam's CEF and, before this, needed per-app GLX/EGL/ICD workarounds).
  #   * Allowed exposes devices + manifests; the application picks the GPU.
  #   * A launcher request (CARDWIRE_REQUEST_DGPU, emitted by cardwire's
  #     Switcheroo shim for KDE's "Launch using Discrete Graphics Card") is
  #     ADVISORY: it grants both GPUs unless the application has an explicit
  #     Blocked row, and it never grants Steam's CEF host (steamwebhelper), whose
  #     inherited request would otherwise hand CEF a NVIDIA stack it cannot drive.
  #     The shim itself emits no vendor variables.
  #   * An injected vendor variable (__GLX_VENDOR_LIBRARY_NAME=nvidia,
  #     VK_LOADER_DRIVERS_SELECT, DRI_PRIME — from a shell profile, a Lutris/
  #     Heroic/Bottles toggle, or a desktop environment holding a stale Switcheroo
  #     cache) is inert for a blocked process, because the hiding covers the
  #     driver *libraries* as well as the manifests: libglvnd finds no NVIDIA
  #     vendor and falls back to Mesa. Without this, the 32-bit Steam client
  #     dlopened libGLX_nvidia and segfaulted inside _XLockDisplay.
  #   * Steam's runtime/launch helpers (bwrap, flatpak, pressure-vessel, srt-bwrap,
  #     pv-adverb, reaper, steam-runtime-l) are always allowed — by comm in the
  #     analyzer *and* in the in-LSM comm whitelist, which is checked before any
  #     other rule. They bind-mount the host's graphics libraries and manifests
  #     into every Proton container, so a blocked one cannot stat a hidden
  #     manifest and aborts the launch ("bwrap: Can't get type of source …"); the
  #     LSM whitelist also removes the race with the analyzer.
  #   * CARDWIRE_ALLOW=1 (nvidia-offload, CUDA wrappers) is an explicit user
  #     grant and wins over everything.
  #
  # Verified 2026-09-26 on system qqy1izkq… / daemon gfm1fk8a… (the build with
  # library hiding re-applied and the sandbox-helper whitelist in place):
  #   * The crash repro — `steam` launched with the stale FORCE+vendor blob that
  #     produced the 19:43 coredump — now runs clean: client Blocked, 13
  #     webhelpers, both windows, 0 NVIDIA libraries mapped, no coredump.
  #   * KDE desktop-entry launch (kioclient exec steam.desktop, its own
  #     PrefersNonDefaultGPU=true left untouched): Blocked, request in env, 13
  #     webhelpers, both windows, 0 NVIDIA libraries.
  #   * A game launched from the UI: DSPGAME.exe Allowed, holding renderD129 with
  #     221-224 NVIDIA libraries, dGPU at D0, stable for 3.5 minutes — i.e. the
  #     library hiding does not break Proton, because the sandbox helpers are
  #     comm-whitelisted in the LSM.
  #   * Gating sanity: a blocked process cannot read libGLX_nvidia or the Vulkan
  #     ICD; an allowed one reads both.
  #   * The in-situ CEF guard: the client's real steamwebhelper processes are all
  #     Blocked with 0 NVIDIA libraries even though the client carries
  #     CARDWIRE_REQUEST_DGPU=1.
  #   * Coredumps: only the two pre-fix client crashes (19:32, 19:43). The one
  #     later entry is a 15 KB wine64-preloader SIGSYS from bwrap's own seccomp
  #     filter — not cardwire (LSM denials are EACCES/ENOENT, never SIGSYS).
  #   * Restart resilience: the rescan re-evaluates ~500 processes at daemon start
  #     (measured), so a nixos-rebuild switch no longer strands a running game.
  #   * Steam games get their policy row on first run and are flippable in
  #     cardwire-gui (verified with a synthetic app id: Blocked row created,
  #     SetAppPolicy accepted, next run Allowed).
  #
  # Known gaps, roughly in order of how likely they are to bite (none of these
  # is fixed yet):
  #   1. Flatpak runtimes ship their OWN copies of the NVIDIA manifests, and
  #      those inodes are not in the per-process block list — measured readable
  #      by a Blocked process:
  #        /var/lib/flatpak/runtime/org.freedesktop.Platform.GL.nvidia-*/
  #        files/**/{vulkan/icd.d/nvidia_icd.json,glvnd/egl_vendor.d/10_nvidia.json}
  #      (plus the GL32 and user-install equivalents). Consequence: a Blocked
  #      Flatpak CEF/Electron app can fail exactly like Steam did. Fix: add those
  #      paths to vendor_meta_inodes() in
  #      packages/patches/cardwire-hide-nvidia-userspace.patch.
  #      Note the nix FHS/steam-run copies are symlinks to the same store inode
  #      and are therefore already covered.
  #   2. FIXED 2026-09-28 by the blacklist inversion. Under the old whitelist,
  #      Bottles, Lutris, Heroic, itch and Minecraft launcher games had no row and
  #      silently stayed on the iGPU. Now they are Allowed by default; the old
  #      36 steam_app_* Allowed rows were deleted in the clean-slate migration.
  #      A blacklist entry is the only row that matters — add it here or flip the
  #      app's discovered row to Blocked in cardwire-gui.
  #   3. FIXED: anything outside cardwire that injects vendor-steering variables
  #      (__GLX_VENDOR_LIBRARY_NAME=nvidia, VK_LOADER_DRIVERS_SELECT, DRI_PRIME —
  #      a shell profile, a Lutris/Heroic/Bottles "use discrete GPU" toggle, or a
  #      desktop environment holding a stale Switcheroo cache) is now inert for a
  #      blocked process, because cardwire-hide-nvidia-userspace.patch hides the
  #      NVIDIA *driver libraries* as well as the manifests: libglvnd finds no
  #      vendor and falls back to Mesa.
  #      This is what the 19:43 crash demanded: the 32-bit Steam client, launched
  #      with the stale FORCE+vendor blob, dlopened libGLX_nvidia from
  #      /run/opengl-driver-32 and segfaulted inside _XLockDisplay/_XLockDisplay's
  #      strchr (vgui2_s.so/steamui.so on the stack). After the patch the same
  #      launch maps 0 NVIDIA libraries, keeps 13 webhelpers and both windows, and
  #      produces no coredump.
  #      A previous attempt at this broke every Proton launch: pressure-vessel's
  #      `bwrap` runs as a blocked process and stats each host library it
  #      bind-mounts ("bwrap: Can't get type of source …: No such file or
  #      directory"). That is fixed the right way now — bwrap/flatpak/
  #      pressure-vessel/srt-bwrap/pv-adverb/reaper/steam-runtime-l are in the
  #      in-LSM comm whitelist (manager.rs), which the hook consults before any
  #      other rule, so their stats always succeed (no race) while every *other*
  #      blocked process still cannot load the driver. Verified after the change:
  #      a game launched from the UI held renderD129 with 221-224 NVIDIA libraries.
  #   4. CARDWIRE_ALLOW=1 overrides an explicit Blocked row (deliberate). So
  #      `nvidia-offload steam` still reproduces the CEF crash. If Blocks should
  #      be absolute, check the DB Blocked row before CARDWIRE_ALLOW in
  #      analyzer::evaluate_app.
  #   5. The request rule only inspects the immediate parent. What makes the
  #      Steam subtree safe today is that a denied parent denies its whole
  #      subtree; walking ancestors would be belt-and-braces.
  #   5b. FIXED, and the duct tape removed (this was the cause of "games run on
  #      the iGPU"): the analyzer is exec-event driven, so restarting cardwired
  #      leaves every already-running process denied. This module used to react to
  #      Steam library writes by re-seeding the whole policy table and restarting
  #      the daemon (PathModified on the steamapps directories) — measured 13
  #      reloads and 16 daemon starts in one hour, three of them inside a game
  #      launch. Dyson Sphere Program was allowed at 16:35:04, the daemon restarted
  #      at 16:35:19, and its Vulkan initialisation then saw only the iGPU: that
  #      session rendered on Intel with zero NVIDIA libraries loaded.
  #      What replaced it:
  #        * packages/patches/cardwire-rescan-running-processes.patch re-evaluates
  #          /proc at daemon start, so any restart — a nixos-rebuild switch, an
  #          upgrade, a crash — no longer strands running applications;
  #        * no file watcher, no library scan, no bulk seeding: cardwire
  #          auto-discovers an app on its first run (now as Allowed, see the
  #          blacklist entry above). A process keeps the decision it got at exec
  #          time, so a row flipped mid-session needs an app relaunch;
  #        * the only policy rows this module still writes are the `steam` and
  #          `steamwebhelper` Blocks (cardwire-steam-client-policy) — without them
  #          a launcher request would grant the client the dGPU and its CEF would
  #          die again.
  #   5c. FIXED: "games stop instantly / all games" (2026-09-26). Cause: the first
  #      version of 5b denied everything a Blocked app spawns, which included
  #      Steam's runtime and launch helpers (reaper, srt-bwrap, pv-adverb, bwrap,
  #      pressure-vessel-wrap). Those helpers bind-mount the host's graphics
  #      libraries and manifests into every Proton container, so a *blocked* bwrap
  #      cannot stat a hidden ICD/implicit-layer manifest and aborts the launch:
  #        bwrap: Can't get type of source …/nvidia_layers.json: No such file
  #      (Games only worked earlier by accident: the stale FORCE+vendor blob made
  #      those helpers Allowed.) Fixes, both in cardwire:
  #        * the analyzer always allows those helpers by name/prefix, independent of
  #          any launcher request, so a game launch works from a terminal or a
  #          desktop entry alike;
  #        * they are also in the in-LSM comm whitelist (manager.rs), which is
  #          checked before any other rule — that removes the race where bwrap's
  #          first stat happens before the daemon has classified its parent, and it
  #          also covers helpers whose /proc/<pid>/environ cannot be read at all.
  #      The Block-inheritance rule itself is gone: the CEF host (steamwebhelper) is
  #      instead excluded from launcher-request grants explicitly, which is what
  #      keeps the client's CEF off the NVIDIA stack when its desktop file asks for
  #      the dGPU. Verified 2026-09-26: games launched from the UI ran on the dGPU (renderD129
  #      + 50–224 NVIDIA libraries mapped, D0),
  #      client Blocked with 11 webhelpers and both windows.
  #   6. Pinning scope. The package *and* its build environment (rustPlatform,
  #      bpf-linker, aya per the pinned Cargo.lock) come from the frozen
  #      `nixpkgs-cardwire` input in flake.nix, with the five patches applied on
  #      top — `nix flake update` cannot move cardwire at all.
  #      What is still coupled to the moving `nixpkgs` is the *module interface*,
  #      `services.cardwired.*`. It cannot be pinned separately: nixpkgs already
  #      imports its own copy of that module through nixpkgs' module list, and
  #      importing a second copy would be a duplicate option declaration. The
  #      failure mode is a loud eval error naming the option (every option this
  #      module sets is explicit, so changed defaults cannot bite silently), or at
  #      worst a service-wiring change — which the re-test checklist in flake.nix
  #      (client, desktop entry, game on the dGPU) is there to catch.
  #   7. A launcher request is a trust boundary only in the sense that any
  #      process in the session can set CARDWIRE_REQUEST_DGPU=1. It merely asks;
  #      an explicit Block still wins and the LSM still enforces per-process
  #      access, so this grants nothing a user could not already do.
  #   8. Battery: an Allowed app keeps the dGPU at D0 by design, and `nvtop` is
  #      allowed (it opens /dev/nvidiactl unconditionally) so it holds the GPU
  #      awake while open — close it to get back to D3cold.
  #
  # Not yet verified end to end:
  #   * A real Steam game holding /dev/dri/renderD129 (the journal shows wine
  #     processes being Allowed, but no game has been inspected on the dGPU).
  #   * A cold reboot (service ordering: seeding before cardwired, powerd, mode).
  #   * cardwire-gui reflecting these rows / toggling them.
  #
  # ── 2026-09-27: MUX=dGPU/Discrete audit, and why battery_auto_switch is off ──
  #
  # Done against cardwire v0.12.1 source (the version in nixpkgs-cardwire) + the
  # local patches. Read this before re-enabling anything that changes mode
  # on its own.
  #
  # battery_auto_switch was the ONE path into apply_mode that never checks
  # whether the target GPU drives the display. watch_battery_status requests
  # Modes::Integrated on every battery event, and apply_mode's Integrated branch
  # calls gpu.block_gpu() with no is_gpu_active() probe — unlike the Manual-mode
  # D-Bus set_block, which does probe and refuses an active GPU. What kept it
  # safe was only `system_type != SystemType::Laptop` returning NotSupported,
  # i.e. a topology accident, not a design guard. With the MUX flipped to
  # Discrete the dGPU is boot_vga and owns the panel, so it is off.
  #
  # Every remaining route to block_gpu, and what guards it (D = design guard,
  # A = accident of topology classification):
  #   * pre_daemon_tasks -> apply_mode_at_startup(None): re-applies the PERSISTED
  #     mode from /var/lib/cardwire/mode.json. If that fails it retries with
  #     Hybrid and persists it, so a mode the topology rejects is not retried
  #     every boot.                                    D (is_default/is_discrete)
  #   * apply_mode(Integrated|Smart) loop: `is_discrete() && !is_default()` is
  #     false for a primary dGPU -> block_gpu is never reached.    D + A
  #   * apply_mode(Manual) + auto_apply_gpu_state: reads gpu_state.json, which
  #     persists a block=true for a PCI address from a previous hybrid session.
  #     A stale entry for the display GPU hits an explicit warn-and-unblock
  #     safety net.                                                      D
  #   * GpuInterface::set_block (D-Bus `cardwire gpu --block N`): refuses the
  #     default GPU, refuses non-Manual mode, probes display state.      D
  #   * SmartPolicyInterface::SetAppPolicy: Allow_dGPU/Force_dGPU/Force_GPU all
  #     unblock, never block.                                    D (by shape)
  #   * monitor_display (external_display_auto_switch): reconciles only
  #     `is_discrete() && !is_default()` GPUs, and if a blocked one is active it
  #     forces mode Hybrid; with a non-default iGPU it returns early on
  #     !is_discrete(). It also re-checks every 5 s (RETRY_INTERVAL), so it can
  #     undo an incorrectly blocked display GPU at startup.      D + recovery
  #   * refresh_gpu (PCI udev bind/unbind): re-enumerates and re-applies the
  #     persisted mode, falling back to Hybrid if that fails.         D
  #   * In Smart mode the default GPU is pushed with block=false, so it is
  #     tracked in the map but never denied; the non-default iGPU in a Desktop
  #     topology is not blocked either (the Smart branch's second condition needs
  #     is_default() && !is_discrete()).                          D
  #
  # Per-app policy (the `steam` Blocked row, Steam game rows) is enforced ONLY
  # when the effective LSM mode is Integrated, Manual or Smart: every hook in
  # crates/cardwire-ebpf/src/main.rs returns at the `is_hybrid()` check before
  # consulting is_inode_blocked, and that check precedes the smart-policy map
  # lookup in helpers.rs. So in Hybrid mode a Blocked row costs nothing.
  #
  # The single point of failure to know about: every guard above resolves
  # is_default(), which comes from check_default_drm_class (a KWin-derived
  # heuristic ranking GPUs by connected eDP/desktop displays, PCI address as
  # tiebreak). If it labels the display GPU as non-default, several of those
  # guards invert at once. On a dGPU-only boot the concrete way that happens is
  # the iGPU's connectors still reading "connected" while muxed away and
  # out-ranking NVIDIA's panel; the system then reports Laptop and Smart is
  # accepted. external_display_auto_switch is what corrects it (within ~5 s).
  #
  # Still open, and NOT fixed by any of the above:
  #   * `cardwire set smart` at boot is wrong on a Discrete MUX — it exits 1
  #     (topology Manual/Desktop) and leaves whatever was persisted. Replace it
  #     with a sysfs probe (boot_vga + driver binding) that picks Hybrid when the
  #     dGPU is the primary display. Until then, set Hybrid by hand before a
  #     dGPU-only boot (see the note in modules/hardware/nvidia.nix).
  #   * FIXED 2026-09-26: modules/hardware/nvidia.nix no longer pins
  #     `__GLX_VENDOR_LIBRARY_NAME=mesa` / a Mesa-only EGL vendor list globally.
  #     That pin was only correct for the hybrid case, and only because CEF/ANGLE
  #     used to crash on a denied device; cardwire now hides the NVIDIA vendor
  #     from blocked processes (manifests *and* libraries), so it was redundant —
  #     and it broke a dGPU-only MUX boot hard, forcing every GLX client through
  #     Mesa (no driver for a dGPU-driven display) and cutting off NVIDIA EGL.
  #     Per-process overrides (nvidia-offload, DaVinci) and Vulkan's ICD list are
  #     unaffected. environment.variables only changes for new sessions, so a
  #     re-login/reboot is needed to drop it from the live one.
  #   * FIXED 2026-09-26: the default display GPU is granted explicitly when it is
  #     discrete (compute_switcheroo_env returns CARDWIRE_ALLOW=1), so a launcher
  #     cannot leave an application with no GPU at all on a Discrete MUX or on a
  #     desktop with no iGPU. When the default is the iGPU it emits nothing and
  #     cardwire's policy decides (that is what keeps the Steam client blocked).
  #
  # ── 2026-09-28: Smart mode inverted to a blacklist ─────────────────────────
  #
  # Why: the whitelist required flipping every game/app to Allowed, and anything
  # unclassified was silently denied. Measured with nvidia-smi: plain
  # `nvidia-smi` got ENOENT on /dev/nvidia0 (checked by hand: os.open returns
  # "No such file or directory", CARDWIRE_ALLOW=1 opens it), and because the
  # report path drops entries whose process has already exited, the short-lived
  # nvidia-smi never even appeared in cardwire-gui's blocked log. The blacklist
  # keeps exactly the same enforcement machinery; only explicit Blocked rows
  # deny.
  #
  # What cardwire-blacklist-mode.patch changes (userspace only, no eBPF change):
  #   * analyzer/models.rs evaluate_app: unclassified → Allowed (the final
  #     fallthrough), unreadable /proc/<pid>/environ → treated as unclassified
  #     instead of denied, xdg-desktop-portal's early deny → allow,
  #     steamwebhelper → deny by name (before its inherited SteamAppId could
  #     rewrite it to an Allowed row), Steam/XDG discovery paths → Allowed.
  #   * file/sql.rs: discovered rows are inserted with policy 1 (Allowed), so
  #     cardwire-gui still lists new apps and can flip them to Blocked.
  #   * Nothing else moves: mode stays Smart, apply_mode still pushes the dGPU
  #     into the block map and tracks the iGPU, so the LSM's smart branch and the
  #     CARDWIRE_ALLOW/Blocked precedence (known gap 4) are untouched.
  #
  # One-time DB migration (done live, clean slate): all whitelist-era rows were
  # deleted — 38 Allowed rows were no-ops, and `konsole`, `virtuoso` and
  # `com.usebottles.bottles` were auto-discovered Blocks that would otherwise
  # have denied those apps by surprise. cardwire-steam-client-policy now reseeds
  # `steam` and `steamwebhelper` as Blocked on every boot (ON CONFLICT DO
  # NOTHING, so GUI flips stick). Re-add a blacklist entry either in that
  # service's SQL or by flipping the app's discovered row in cardwire-gui.
  #
  # Consequences to remember:
  #   * The dGPU is now wakeable by any application. The whitelist was also what
  #     kept it idle; `nvidia-smi`, `nvtop`, a browser enumerating Vulkan, etc.
  #     can wake it. Idle return to D3cold is unchanged once no fd is open.
  #   * Flatpak's private NVIDIA manifests (known gap 1) now only matter for a
  #     blacklisted Flatpak app — none is blacklisted today.
  #   * `nvidia-offload steam` still overrides the Block (known gap 4) and will
  #     still kill the client's CEF. The wrapper stays for CUDA/forced-NVIDIA
  #     work, not for GPU selection: the blacklist needs no help picking the
  #     dGPU.
  #
  # Re-test after this change: plain `nvidia-smi` (must work), the Steam client
  # from KDE/terminal (Blocked, both windows, 0 NVIDIA libraries), a game from
  # the Steam UI (Allowed on first run, dGPU), cardwire-gui app list (steam +
  # steamwebhelper Blocked, a game's row flippable).
}
