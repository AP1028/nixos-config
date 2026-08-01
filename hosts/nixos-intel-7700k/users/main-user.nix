{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/users/main-user.nix
  ];

  users.users.${config.local.username}.extraGroups = [
    "video"
    "input"
  ];
}
