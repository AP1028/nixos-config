{
  config,
  lib,
  pkgs,
  ...
}: let
  harmonyos = pkgs.callPackage ../../packages/harmonyos-sans-font.nix {};
in {
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    sarasa-gothic
    harmonyos
    wqy_zenhei
  ];

  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      sansSerif = ["HarmonyOS Sans" "HarmonyOS Sans SC"];
      serif = ["Noto Serif" "Noto Serif CJK SC"];
      monospace = ["Sarasa Gothic"];
      emoji = ["Noto Color Emoji"];
    };
    cache32Bit = true;
  };

  console.font = "Lat2-Terminus16";
  console.useXkbConfig = true;
}
