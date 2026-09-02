{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.steam-arm64;
in {
  options.programs.steam-arm64 = {
    enable = lib.mkEnableOption ''
      the native arm64 Steam client (Valve's aarch64 publicbeta build).
      Only meaningful on aarch64-linux.
    '';

    remotePlay.openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open ports in the firewall for Steam Remote Play.";
    };

    dedicatedServer.openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open ports in the firewall for Source Dedicated Server.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The client needs the host GL/Vulkan stack (Asahi mesa) wired up so
    # /run/opengl-driver exposes the DRI/ICD drivers to the FHS sandbox.
    hardware.graphics.enable = true;

    # Steam controller udev rules + uinput module.
    hardware.steam-hardware.enable = true;

    environment.systemPackages = [
      (pkgs.callPackage ../../packages/steam-arm64.nix { })
    ];

    networking.firewall = lib.mkMerge [
      (lib.mkIf cfg.remotePlay.openFirewall {
        allowedTCPPorts = [ 27036 ];
        allowedUDPPortRanges = [ { from = 27031; to = 27036; } ];
      })

      (lib.mkIf cfg.dedicatedServer.openFirewall {
        allowedTCPPorts = [ 27015 ];
        allowedUDPPorts = [ 27015 ];
      })
    ];
  };
}
