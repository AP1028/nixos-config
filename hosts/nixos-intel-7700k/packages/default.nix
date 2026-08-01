{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/packages/common
    ../../../modules/packages/common/vm-common.nix
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    bat
    btop
    curl
    eza
    fd
    jq
    kdePackages.kdialog
    ripgrep
    rsync
    tree
    vim
  ];
}
