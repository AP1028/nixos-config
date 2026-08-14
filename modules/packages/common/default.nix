{pkgs, config, inputs, ...}: {
  # Home-manager module is imported per-host in flake.nix with the matching
  # release (VMs: home-manager-stable; desktops: home-manager), so this module
  # only carries the shared home-manager configuration.
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
