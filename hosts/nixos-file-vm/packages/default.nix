{pkgs, ...}: {
  # File server VM: keep it lean. The web UI is ./services/file-web.nix.
  environment.systemPackages = with pkgs; [
    # handy for testing the ZFS pool / SMB shares
    smartmontools
  ];
}
