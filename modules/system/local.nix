{ config, lib, ... }:
let
  localFile = ../../local.nix;
  localConfig = import localFile;
in {
  options.local.username = lib.mkOption {
    type = lib.types.str;
    default = localConfig.username;
    description = "Primary user name for this machine (set via local.nix)";
  };

  options.local.description = lib.mkOption {
    type = lib.types.str;
    default = localConfig.description;
    description = "Full name / description of the primary user (set via local.nix)";
  };

  options.local.configDir = lib.mkOption {
    type = lib.types.str;
    default = localConfig.configDir;
    description = "Path to the nixos flake config directory (set via local.nix)";
  };

  config = {
    boot.loader.systemd-boot.configurationLimit = 25;
  };
}
