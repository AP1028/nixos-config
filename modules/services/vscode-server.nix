{
  config,
  lib,
  pkgs,
  ...
}: {
  services.vscode-server.enable = true;
  programs.nix-ld.enable = true;
}
