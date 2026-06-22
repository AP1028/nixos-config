{
  config,
  lib,
  pkgs,
  ...
}: {
  users.users.service = {
    shell = pkgs.zsh;
    isNormalUser = true;
    description = "Service";
    group = "service";
    homeMode = "770";
    createHome = true;
    home = "/home/service";
  };
  users.groups.service = {};

  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    ohMyZsh = {
      enable = true;
      plugins = ["history" "git"];
      theme = "bira";
    };
  };
}
