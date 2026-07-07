{
  config,
  lib,
  pkgs,
  ...
}: {
  # zsh must be enabled system-wide so it's a valid login shell and gets the
  # NixOS environment (/etc/zshenv). The actual interactive config lives in
  # home-manager (modules/home/zsh) so it is written to ~/.zshrc.
  programs.zsh.enable = true;

  users.users.${config.local.username} = {
    shell = pkgs.zsh;
    isNormalUser = true;
    description = config.local.description;
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };
}
