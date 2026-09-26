{
  config,
  lib,
  pkgs,
  ...
}: let
  # Environment for a process that must render/compute on the NVIDIA dGPU.
  # This is the set Cardwire's Switcheroo shim advertises for "Launch using
  # Discrete Graphics Card", plus an explicit NVIDIA EGL vendor file.
  dgpuEnv = {
    # Cardwire: unblock /dev/nvidia* for this process and hide the iGPU from it.
    CARDWIRE_FORCE_DGPU = "1";

    # Vendor offload variables (libglvnd / Vulkan loader).
    __NV_PRIME_RENDER_OFFLOAD = "1";
    __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    __VK_LAYER_NV_optimus = "NVIDIA_only";
    VK_LOADER_DRIVERS_SELECT = "*nvidia*,*nouveau*";

    # nvidia.nix no longer pins the EGL vendor list globally (see the comment
    # there), so offloaded EGL clients select NVIDIA explicitly.
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
  };

  dgpuExports = lib.concatLines (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") dgpuEnv
  );

  # Where the Steam libraries live (used by the policy seeding below).
  mainUser = config.local.username;
  home = config.users.users.${mainUser}.home;
in {
  # Cardwire installs eBPF LSM hooks that make the blocked GPU's device nodes
  # (/dev/dri/renderD*, /dev/nvidia*, nvidia modeset/uvm, GPU sysfs attributes)
  # return -ENOENT to every process that has not been explicitly allowed. This
  # is what replaces the per-application bwrap / GLX / EGL / Vulkan-ICD
  # workarounds: a blocked GPU cannot be woken by Vulkan ICD enumeration, an
  # Electron renderer, a GTK app or nvtop, no matter how it is packaged.
  #
  # Smart mode blocks the dGPU by default and allows it per application:
  #   - KDE's "Launch using Discrete Graphics Card" (Switcheroo D-Bus shim)
  #   - `nvidia-offload` / `CARDWIRE_FORCE_DGPU=1` / `CARDWIRE_ALLOW=1`
  #   - the per-application list in cardwire-gui
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

  # ── Persistent per-application "force dGPU" policy ───────────────────
  # nixpkgs' cardwire only knows Blocked/Allowed per application, so pinning an
  # app to the dGPU otherwise needs CARDWIRE_FORCE_DGPU=1 at launch — and for a
  # Steam game that means a per-game launch option, because a game inherits the
  # environment of the already-running Steam client, not of whatever started
  # the shortcut. The overlay (packages/cardwire-forced-policy.nix) adds
  # GpuPolicy::Forced = 2 and fixes RequestProcessAccess; the services below
  # then seed every installed Steam app id into cardwire's policy DB, so games
  # run on the dGPU with no per-game configuration while the Steam client
  # itself stays blocked on the iGPU.
  nixpkgs.overlays = [
    (import ../../packages/cardwire-forced-policy.nix)
  ];

  # The daemon only reads app_policies at startup: seed before it starts.
  systemd.services.cardwire-steam-policies = {
    description = "Pin installed Steam games to the dGPU in cardwire";
    wantedBy = ["multi-user.target"];
    before = ["cardwired.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    path = [pkgs.sqlite pkgs.gnugrep pkgs.coreutils];
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

      dirs=()
      for d in ${home}/.steam/steam/steamapps ${home}/.local/share/Steam/steamapps; do
          [ -d "$d" ] && dirs+=("$d")
      done
      for vdf in "''${dirs[@]}"; do
          [ -f "$vdf/libraryfolders.vdf" ] || continue
          while IFS= read -r path; do
              [ -d "$path/steamapps" ] && dirs+=("$path/steamapps")
          done < <(grep -oP '"path"\s+"\K[^"]+' "$vdf/libraryfolders.vdf" || true)
      done

      count=0
      while IFS= read -r id; do
          [ -n "$id" ] || continue
          # policy 2 = Forced (added by the patch), 1 = Allowed, 0 = Blocked.
          sqlite3 "$db" "INSERT INTO app_policies (binary_name, display_name, desktop_file_id, icon_name, policy)
                         VALUES ('steam_app_$id', 'Steam Game $id', NULL, 'steam_icon_$id', 2)
                         ON CONFLICT(binary_name) DO UPDATE SET policy = 2;"
          count=$((count + 1))
      done < <(for d in "''${dirs[@]}"; do grep -hoP '"appid"\s+"\K[0-9]+' "$d"/appmanifest_*.acf 2>/dev/null || true; done | sort -u)

      echo "cardwire: pinned $count Steam game(s) to the dGPU"
    '';
  };

  # A library change (game installed/removed) re-seeds and reloads the daemon,
  # so new games are picked up without a reboot.
  systemd.services.cardwire-steam-reload = {
    description = "Re-seed cardwire Steam policies after a library change";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart cardwire-steam-policies.service cardwired.service";
    };
  };
  systemd.paths.cardwire-steam-reload = {
    wantedBy = ["multi-user.target"];
    pathConfig.PathModified = [
      "${home}/.steam/steam/steamapps"
      "${home}/.local/share/Steam/steamapps"
    ];
  };

  environment.systemPackages = [
    # Replaces the stock nvidia-offload script (disabled in nvidia.nix): the
    # same vendor variables plus the Cardwire routing variable, without which
    # the LSM hook keeps /dev/nvidia* blocked. Also how CUDA/CLI work reaches
    # the dGPU: `nvidia-offload python train.py`.
    (pkgs.writeShellScriptBin "nvidia-offload" ''
      ${dgpuExports}
      exec "$@"
    '')

    # nvtop opens /dev/nvidiactl unconditionally, so it needs an explicit allow.
    (lib.hiPrio (pkgs.writeShellScriptBin "nvtop" ''
      export CARDWIRE_ALLOW=1
      exec ${pkgs.nvtopPackages.nvidia}/bin/nvtop "$@"
    ''))

    # NOTE: there is deliberately no "Steam (dGPU)" launcher here. Forcing the
    # Steam *client* onto the dGPU hides the iGPU from its whole process tree,
    # and CEF under Xwayland then cannot build its GLX/EGL surface (logs:
    # GLXBadPixmap / failed to create drawable, ANGLE eglInitialize
    # EGL_NOT_INITIALIZED), so the GPU process crash-loops, GPU acceleration is
    # disabled and the window is created but never painted — which looks like
    # "Steam is not showing anywhere".
    # Measured 2026-09-25: forced client = 6 crash-loop restarts then
    # "Disabling GPU acceleration: Disabled/CrashCount"; plain client = clean
    # "GPU Report: End [0]" with the dGPU left in D3cold.
    # Launch plain Steam (client on the iGPU) and let the per-application
    # Forced policy above route the games themselves.
  ];
}
