{config, pkgs, ...}: let
  sudo-env = pkgs.writeShellScriptBin "sudo-env" ''
    sudo -v
    while sudo -nv 2>/dev/null; do sleep 240; done &
    KEEPER=$!
    trap 'kill $KEEPER 2>/dev/null' EXIT
    exec zsh "$@"
  '';
in {
  environment.systemPackages = [sudo-env];
}
