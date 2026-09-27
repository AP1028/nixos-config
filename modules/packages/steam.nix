{
  pkgs,
  inputs,
  ...
}: {
  nixpkgs.overlays = [
    inputs.nix-gaming-edge.overlays.proton-cachyos
  ];

  # NOTE: Steam's shipped .desktop sets PrefersNonDefaultGPU=true /
  # X-KDE-RunOnDiscreteGpu=true, so KDE injects switcheroo-control's
  # discrete-GPU environment when launching it. That is deliberately left
  # alone — cardwire is what has to cope with an application requesting the
  # dGPU (see modules/hardware/cardwire.nix and the cardwire patches), not the
  # launcher's configuration.

  # Steam with Proton GE and CJK font support inside the runtime
  programs.steam = {
    enable = true;

    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        attr # fixes libattr.so.1 ATTR_1.3 not found in Steam runtime
      ];
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
