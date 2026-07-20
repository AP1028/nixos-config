{pkgs, config, inputs, ...}: {
  # Enable home-manager for every machine that pulls in the common module
  # (desktops via their packages set, VMs via vm-common.nix). This is what
  # makes modules/home (zsh, starship, fastfetch, ...) apply everywhere.
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ../opencode.nix
  ];

  home-manager.backupFileExtension = "hm-backup";
  home-manager.users.${config.local.username} = {
    imports = [ ../../home ];
  };

  environment.systemPackages = with pkgs; [
    git
    wget
    fastfetch
    htop
    pciutils
    unzip
    nmap
    killall
    iotop
  ];
}
