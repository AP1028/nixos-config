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
        attr
        libcap
        pkgsi686Linux.glibc
        pkgsi686Linux.libcap
        pkgsi686Linux.xz
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
