{
  config,
  pkgs,
  ...
}: {
  imports = [ ./fastfetch ./zsh ];

  home = {
    stateVersion = "25.05";
    packages = [
    ];
  };

  programs = {
    home-manager.enable = true;
  };
}
