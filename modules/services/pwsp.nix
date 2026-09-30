{
  config,
  lib,
  ...
}: {
  # PipeWire Soundpad (pwsp): open-source Linux-native Soundpad alternative.
  # Package + per-user daemon come from the pwsp flake (nixosModules.default,
  # imported in flake.nix). The daemon creates its own PipeWire virtual mic;
  # select "pwsp" as the microphone in Discord/Teamspeak/etc.
  services.pipewire-soundpad = {
    enable = true;

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
