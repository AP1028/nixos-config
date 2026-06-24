{
  config,
  lib,
  pkgs,
  ...
}: let
  harmonyos = pkgs.callPackage ../../packages/harmonyos-sans-font.nix {};

  # Import your new local package file safely using conditional evaluation
  ms-fonts =
    if builtins.pathExists /etc/nixos/git-excluded/fonts/ms-fonts.zip
    then pkgs.callPackage ../../packages/ms-fonts.nix {}
    else null;
in {
  # Accept the unfree Microsoft font licenses
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "corefonts"
      "vista-fonts"
    ];

  fonts.packages = with pkgs;
    [
      corefonts
      vista-fonts

      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      sarasa-gothic
      harmonyos
      wqy_zenhei
    ]
    ++ (lib.optional (ms-fonts != null) ms-fonts); # Only include if file exists

  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      sansSerif = ["Microsoft YaHei" "HarmonyOS Sans" "HarmonyOS Sans SC"];
      serif = ["SimSun" "Noto Serif" "Noto Serif CJK SC"];
      monospace = ["Sarasa Gothic"];
      emoji = ["Noto Color Emoji"];
    };
    cache32Bit = true;
  };

  console.font = "Lat2-Terminus16";
  console.useXkbConfig = true;
}
