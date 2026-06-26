{pkgs, ...}: {
  # Steam with Proton GE and CJK font support inside the runtime
  programs.steam = {
    enable = true;

    extraCompatPackages = with pkgs; [
      proton-ge-bin
      inputs.nix-proton-cachyos.packages.${system}.proton-cachyos
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
