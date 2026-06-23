{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../system/zsh.nix
  ];

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
