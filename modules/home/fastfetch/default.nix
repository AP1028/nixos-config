{ config, lib, ... }:
let
  selected = "detailed";

  presetDir = ./presets;
  presetNames = [ "detailed" ];

  presetFiles = lib.genAttrs presetNames (
    name: ".local/share/fastfetch/presets/${name}.jsonc"
  );
in {
  programs.fastfetch.enable = true;

  home.file = lib.mapAttrs' (name: target: {
    name = target;
    value.source = presetDir + "/${name}.jsonc";
  }) presetFiles;

  xdg.configFile."fastfetch/config.jsonc".source = presetDir + "/${selected}.jsonc";
}
