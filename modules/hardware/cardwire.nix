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
in {
  # Cardwire installs eBPF LSM hooks that make the blocked GPU's device nodes
  # (/dev/dri/renderD*, /dev/nvidia*, nvidia modeset/uvm, GPU sysfs attributes)
  # return -ENOENT to every process that has not been explicitly allowed. This
  # is what replaces the per-application bwrap / GLX / EGL / Vulkan-ICD
  # workarounds: a blocked GPU cannot be woken by Vulkan ICD enumeration, an
  # Electron renderer, a GTK app or nvtop, no matter how it is packaged.
  #
  # Smart mode blocks the dGPU by default and allows it per application. Only
  # two states exist here — "iGPU only" and "both GPUs" — never "iGPU hidden":
  #   - KDE's "Launch using Discrete Graphics Card" (Switcheroo D-Bus shim)
  #   - `nvidia-offload` (CARDWIRE_ALLOW=1 + PRIME vendor vars)
  #   - the per-application list in cardwire-gui
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
      battery_auto_switch = true;
      battery_auto_switch_mode = "smart"; # mode to use while on AC power
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
  # for this (its config struct has exactly the five keys above), but it only
  # touches the service when `systemctl is-enabled nvidia-powerd.service`
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

  # Cardwire persists the active mode, but a fresh state starts in hybrid. Set
  # smart explicitly at boot; battery_auto_switch takes over from there.
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
  # The four local patches (packages/patches/) are applied on top; the
  # measurements behind each one are in "ROBUSTNESS NOTES" at the end of this
  # file:
  #   cardwire-hide-vendor-manifests      blocked processes cannot read the NVIDIA
  #                                       manifests (device nodes alone crash CEF)
  #   cardwire-never-hide-igpu            FORCE_* never hide the iGPU; launcher
  #                                       requests are advisory; Steam's runtime
  #                                       helpers are always allowed; the CEF host
  #                                       is excluded from request grants
  #   cardwire-rescan-running-processes   re-evaluate /proc at daemon start, so a
  #                                       restart cannot strand a running game
  #   cardwire-steam-discovery            resolve steam_app_<id> before the XDG
  #                                       heuristics, so a new game gets its row
  services.cardwired.package = let
    cardwireNixpkgs = import inputs.nixpkgs-cardwire.outPath {
      inherit (pkgs.stdenv.hostPlatform) system;
      config = config.nixpkgs.config or { };
    };
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
          (patch "cardwire-hide-vendor-manifests")
          (patch "cardwire-never-hide-igpu")
          (patch "cardwire-rescan-running-processes")
          (patch "cardwire-steam-discovery")
        ];
    });

  # ── Policy for the Steam client itself ───────────────────────────────
  # One row. No library scanning, no file watcher, no restart machinery: the
  # watcher that re-seeded on every Steam write was restarted 13 times in an hour
  # and silently demoted a running game to the iGPU (see "ROBUSTNESS NOTES" at
  # the end of this file for the measurement).
  #
  # The client must be explicitly Blocked. Its CEF/ANGLE cannot drive the NVIDIA
  # stack (measured: no window at all), and its own desktop file sets
  # PrefersNonDefaultGPU=true, so KDE asks cardwire to launch it on the dGPU; the
  # launcher request is advisory and this Block is what makes it lose. Without a
  # row the client would be unclassified — and a launcher request *would* grant
  # it — so this row is load-bearing, not a convenience. Existing choices are
  # kept (ON CONFLICT DO NOTHING), so flipping it in cardwire-gui sticks.
  #
  # Games are not seeded any more. cardwire auto-discovers a Steam game on its
  # first run and adds it as Blocked; flip it to Allowed once in cardwire-gui.
  # Relaunch the game afterwards — a process keeps the decision it got at exec.
  systemd.services.cardwire-steam-client-policy = {
    description = "Keep the Steam client itself blocked in cardwire";
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

    # nvtop opens /dev/nvidiactl unconditionally, so it needs an explicit allow.
    (lib.hiPrio (pkgs.writeShellScriptBin "nvtop" ''
      export CARDWIRE_ALLOW=1
      exec ${pkgs.nvtopPackages.nvidia}/bin/nvtop "$@"
    ''))

    # No Steam launcher and no per-game launch options: cardwire auto-discovers a
    # game on its first run and adds it Blocked, then it is flipped to Allowed once
    # in cardwire-gui and picks the GPU itself. The client stays Blocked/iGPU, so
    # it never wakes the dGPU.
  ];

  # ─────────────────────────────────────────────────────────────────────────
  # ROBUSTNESS NOTES — what is guaranteed, what is not, and what is untested.
  #
  # The model (enforced by packages/patches/*.patch on the pinned package):
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
  #     Blocked row. It carries no vendor variables, because those make libglvnd
  #     load the NVIDIA driver directly, bypassing the manifest hiding above.
  #   * An explicit Block extends to what the blocked app spawns (a denied
  #     parent denies its subtree), unless the child has a policy row of its own.
  #   * CARDWIRE_ALLOW=1 (nvidia-offload, CUDA wrappers) is an explicit user
  #     grant and wins over everything.
  #
  # Verified 2026-09-26 (daemon 3sz9c5sn…, system ad0gvqcb…):
  #   * KDE desktop launch of Steam, whose own .desktop says
  #     PrefersNonDefaultGPU=true (deliberately left untouched): client Blocked,
  #     request in env, 0 vendor vars, 0 NVIDIA libs mapped, 13 webhelpers and
  #     both X11 windows — i.e. the dGPU request no longer breaks it.
  #   * That launch's helpers (srt-bwrap, pv-adverb, steamwebhelper) all denied,
  #     so CEF kept using Mesa; the client itself never woke the dGPU.
  #   * Games: steam_app_* rows Allowed, both GPUs + NVIDIA ICD readable.
  #   * Unlisted app + launcher request -> Allowed (the action still works).
  #   * Blocked process cannot read /run/opengl-driver{,-32} NVIDIA manifests.
  #   * Discord (Electron) denied GPU access and running normally.
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
  #      packages/patches/cardwire-hide-vendor-manifests.patch.
  #      Note the nix FHS/steam-run copies are symlinks to the same store inode
  #      and are therefore already covered.
  #   2. Only Steam games are seeded (36 steam_app_* rows). Bottles, Lutris,
  #      Heroic, itch and Minecraft launcher games have no row, so they are
  #      Blocked by default and silently stay on the iGPU. Fix: seed them too, or
  #      toggle them in cardwire-gui (which is what the rows exist for).
  #   3. Anything OUTSIDE cardwire that injects vendor-steering variables
  #      (__GLX_VENDOR_LIBRARY_NAME=nvidia, VK_LOADER_DRIVERS_SELECT, DRI_PRIME)
  #      still bypasses the gating: the driver loads, then cannot open the denied
  #      nodes, and fragile CEF/ANGLE apps can crash. Measured 2026-09-26: 34
  #      NVIDIA libraries mapped into a Blocked Steam client that way, then
  #      "X Error: BadValue" + segfault.
  #      Hiding the *libraries* from blocked processes would fix this and was
  #      tried — it breaks every Proton launch instead, because pressure-vessel's
  #      `bwrap` runs blocked and stats each host library it bind-mounts
  #      ("Can't get type of source .../libnvidia-egl-wayland2.so.1.0.2: No such
  #      file or directory"), and because that allow is granted asynchronously the
  #      stat can also race it. So: cardwire hides manifests (pressure-vessel only
  #      warns about unreadable ICDs) but never the libraries.
  #      What keeps this from biting in practice: cardwire's own Switcheroo shim
  #      emits no vendor variables at all (see cardwire-never-hide-igpu.patch), so
  #      the desktop paths are clean — verified 2026-09-26: a KDE desktop-entry
  #      launch carries only CARDWIRE_REQUEST_DGPU=1. The remaining exposure is a
  #      hand-written injection (shell profile, Lutris/Heroic/Bottles "use
  #      discrete GPU" toggle, Steam per-game launch option); use `nvidia-offload`
  #      for those, which pairs the variables with CARDWIRE_ALLOW=1. Audited
  #      2026-09-26: no live injector in ~/.config or ~/.local/share/applications.
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
  #          auto-discovers a Steam game on its first run (as Blocked) and it is
  #          flipped to Allowed once in cardwire-gui. A process keeps the decision
  #          it got at exec time, so a game toggled mid-session must be relaunched;
  #        * the only policy this module still writes is the single `steam` row
  #          (cardwire-steam-client-policy) that keeps the client itself Blocked —
  #          without it a launcher request would grant the client the dGPU and its
  #          CEF would die again.
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
  #      the dGPU. Verified 2026-09-26: two different games launched from the UI
  #      both ran on the dGPU (renderD129 + 50–138 NVIDIA libraries mapped, D0),
  #      client Blocked with 11 webhelpers and both windows.
  #   6. Pinning scope. The package *and* its build environment (rustPlatform,
  #      bpf-linker, aya per the pinned Cargo.lock) come from the frozen
  #      `nixpkgs-cardwire` input in flake.nix, with the four patches applied on
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
}
