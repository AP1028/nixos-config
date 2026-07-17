{
  pkgs,
  inputs,
  ...
}: {
  nixpkgs.overlays = [
    inputs.nix-gaming-edge.overlays.proton-cachyos
  ];

  # Steam with Proton GE and CJK font support inside the runtime
  programs.steam = {
    enable = true;

    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        attr # fixes libattr.so.1 ATTR_1.3 not found in Steam runtime
      ];
      extraProfile = ''
        # Remove GPU hints so steamwebhelper uses iGPU (games unaffected)
        DESKTOP_SRC="/run/current-system/sw/share/applications/steam.desktop"
        DESKTOP_DST="$HOME/.local/share/applications/steam.desktop"
        if [ -f "$DESKTOP_SRC" ] && [ ! -f "$DESKTOP_DST" ]; then
          mkdir -p "$(dirname "$DESKTOP_DST")"
          sed 's/^PrefersNonDefaultGPU=.*/PrefersNonDefaultGPU=false/;s/^X-KDE-RunOnDiscreteGpu=.*/X-KDE-RunOnDiscreteGpu=false/' \
            "$DESKTOP_SRC" > "$DESKTOP_DST"
        fi
      '';
    };

    extraCompatPackages = with pkgs; [
      proton-ge-bin
      proton-cachyos
    ];
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    dedicatedServer.openFirewall = true;

    # CJK fonts inside the Steam Linux runtime sandbox
    fontPackages = with pkgs; [
      wqy_zenhei
      noto-fonts-cjk-sans
    ];
  };
}
