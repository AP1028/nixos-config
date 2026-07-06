{ config, lib, ... }:
let
  cfg = config.local.home.fastfetch;

  selected = "detailed";

  presetDir = ./presets;
  presetNames = [ "detailed" ];

  presetFiles = lib.genAttrs presetNames (
    name: ".local/share/fastfetch/presets/${name}.jsonc"
  );
in {
  options.local.home.fastfetch.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to install the tweaked fastfetch preset config.";
  };

  config = lib.mkIf cfg.enable {
    programs.fastfetch.enable = true;

    home.file = lib.mapAttrs' (name: target: {
      name = target;
      value.source = presetDir + "/${name}.jsonc";
    }) presetFiles;

    xdg.configFile."fastfetch/config.jsonc".source = presetDir + "/${selected}.jsonc";
  };
}
