{
  config,
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
  # Smart mode blocks the dGPU by default and allows it per application. Only
  # two states exist here — "iGPU only" and "both GPUs" — never "iGPU hidden":
  #   - KDE's "Launch using Discrete Graphics Card" (Switcheroo D-Bus shim)
  #   - `nvidia-offload` (CARDWIRE_ALLOW=1 + PRIME vendor vars)
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

  # ── Per-application allow list for Steam games ───────────────────────
  # Cardwire is only an allow/deny gate: "Allowed" means *both GPUs are
  # available* and the application itself decides which one to use — no forcing
  # and no environment variables (CARDWIRE_FORCE_DGPU hides the iGPU, which
  # breaks window presentation for CEF and Proton games, and is never used).
  # Seeding the policy for every installed game just pre-fills the same list
  # cardwire-gui shows, so a game needs no per-game launch option; the client
  # itself has no row, so it stays Blocked/iGPU and never wakes the dGPU.
  # Existing rows are left untouched (ON CONFLICT DO NOTHING), so whatever you
  # toggle in the GUI survives reboots.

  # The daemon only reads app_policies at startup: seed before it starts.
  systemd.services.cardwire-steam-policies = {
    description = "Allow the dGPU for installed Steam games in cardwire";
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
          # 1 = Allowed (both GPUs available, the app picks), 0 = Blocked.
          # DO NOTHING keeps any choice already made in cardwire-gui.
          sqlite3 "$db" "INSERT INTO app_policies (binary_name, display_name, desktop_file_id, icon_name, policy)
                         VALUES ('steam_app_$id', 'Steam Game $id', NULL, 'steam_icon_$id', 1)
                         ON CONFLICT(binary_name) DO NOTHING;"
          count=$((count + 1))
      done < <(for d in "''${dirs[@]}"; do grep -hoP '"appid"\s+"\K[0-9]+' "$d"/appmanifest_*.acf 2>/dev/null || true; done | sort -u)

      echo "cardwire: $count installed Steam game(s) allowlisted (existing entries untouched)"
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

    # No Steam launcher and no per-game launch options: games are simply
    # Allowed by policy (seeded above, or toggled in cardwire-gui) and pick the
    # GPU themselves. The client stays Blocked/iGPU, so it never wakes the dGPU.
  ];
}
