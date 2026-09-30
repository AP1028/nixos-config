{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.steam-asahi;

  # The host's pkgs.fex/muvm are patched for the Cadence work (FEX carries the
  # 16K jemalloc patch + diagnostics, muvm a --no-network patch).  FEX runs
  # inside the *4K-page* muvm guest, where a 16K jemalloc build is wrong (and
  # was observed to segfault), so instantiate a stock nixpkgs for this stack.
  # Everything here substitutes from the binary cache.
  stock = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = pkgs.config;
  };
in {
  options.programs.steam-asahi = {
    enable = lib.mkEnableOption ''
      Steam for aarch64-linux (the Fedora Asahi Remix stack: Valve's x86_64
      launcher under FEX-Emu in a muvm microVM).  Only meaningful on
      aarch64-linux.
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
    # Asahi mesa must be present for the Steam client and its FEX thunks.
    hardware.graphics.enable = true;

    # Steam controller udev rules + uinput module.
    hardware.steam-hardware.enable = true;

    # Steam's runtime scripts call /sbin/ldconfig.  NixOS has no /sbin; inside
    # the muvm guest /usr is bound to the Fedora rootfs, so this resolves to
    # the Fedora /sbin there.  On the host the symlink dangles harmlessly.
    system.activationScripts.steam-asahi-sbin.text = ''
      ${pkgs.coreutils}/bin/ln -sfn usr/sbin /sbin
    '';

    environment.systemPackages = [
      (pkgs.callPackage ../../packages/steam-asahi.nix {
        fex = stock.fex;
        muvm = stock.muvm;
        # The Steam UI (CEF) runs in a pressure-vessel container that only
        # sees /usr/share/fonts of the guest; the Fedora rootfs has Latin
        # fonts only, so carry the host's CJK-capable set.
        fonts = with pkgs; [
          corefonts
          vista-fonts
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-cjk-serif
          sarasa-gothic
          wqy_zenhei
          (pkgs.callPackage ../../packages/harmonyos-sans-font.nix {})
        ];
      })
    ];

    networking.firewall = lib.mkMerge [
      (lib.mkIf cfg.remotePlay.openFirewall {
        allowedTCPPorts = [27036];
        allowedUDPPortRanges = [
          {
            from = 27031;
            to = 27036;
          }
        ];
      })

      (lib.mkIf cfg.dedicatedServer.openFirewall {
        allowedTCPPorts = [27015];
        allowedUDPPorts = [27015];
      })
    ];
  };
}
