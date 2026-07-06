{
  config,
  pkgs,
  ...
}: {
  imports = [ ./fastfetch ];

  home = {
    stateVersion = "25.05";
    packages = [
    ];
  };

  programs = {
    home-manager.enable = true;
  };
}
