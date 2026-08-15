{pkgs, ...}: {
  # File server VM: keep it lean for now; add the web UI here later.
  environment.systemPackages = with pkgs; [
    # handy for testing the ZFS pool / SMB shares
    smartmontools
  ];
}
