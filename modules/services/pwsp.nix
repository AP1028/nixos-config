{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  # PipeWire Soundpad (pwsp): open-source Linux-native Soundpad alternative.
  # Package + per-user daemon come from the pwsp flake (nixosModules.default,
  # imported in flake.nix). The daemon creates its own PipeWire virtual mic;
  # select "pwsp" as the microphone in Discord/Teamspeak/etc.
  services.pipewire-soundpad = {
    enable = true;

    # Local patch: upstream HEAD (rev 2170518, 2026-08-24) fails to compile
    # against libspa 0.10 (bundled in its own Cargo.lock): pwsp-lib calls
    # .map/.map_err on registry.destroy_global(), which returns a SpaResult
    # newtype in libspa 0.10, not a Result. The patch makes the destroy
    # best-effort. Remove once upstream fixes the API usage.
    package = inputs.pwsp.packages.${pkgs.system}.default.overrideAttrs (old: {
      patches = (old.patches or []) ++ [
        # pwsp-lib vs libspa 0.10 (see comment above).
        ../../packages/pwsp/pwsp-libspa-destroy-global.patch
        # Upstream HEAD misses an import in pwsp-gui body.rs
        # (is_symlink used at line 637 without `use crate::gui::is_symlink`).
        ../../packages/pwsp/gui-is-symlink-import.patch
      ];
    });

    daemon = {
      enable = true;
      # LAN web controller listens on 0.0.0.0:3030 by default — leave off
      # unless you actually want phone-browser playback control; enable via
      # services.pipewire-soundpad.daemon.web.enable = true.
      web.enable = lib.mkForce false;
    };

    # Global hotkeys read /dev/input directly; only trusted users.
    hotkeys.users = ["tianyixia"];
  };
}
