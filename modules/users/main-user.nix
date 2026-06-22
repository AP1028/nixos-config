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
    description = "Main User";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };
}
