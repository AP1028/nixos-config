{config, pkgs, ...}: let
  sudo-env = pkgs.writeShellScriptBin "sudo-env" ''
    sudo -v
    exec zsh "$@"
  '';
in {
  environment.systemPackages = [sudo-env];
}
