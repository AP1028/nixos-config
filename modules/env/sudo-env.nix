{config, pkgs, ...}: let
  sudo-env = pkgs.writeShellScriptBin "sudo-env" ''
    exec sudo -u "$USER" zsh "$@"
  '';
in {
  environment.systemPackages = [sudo-env];
}
