{config, pkgs, ...}: let
  sudo-env = pkgs.writeShellScriptBin "sudo-env" ''
    HOME="$HOME" USER="$USER" exec sudo -E zsh "$@"
  '';
in {
  environment.systemPackages = [sudo-env];
}
