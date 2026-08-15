{
  config,
  lib,
  pkgs,
  ...
}: {
  # SMB file server for the HDD ZFS pool.
  #
  # The pool (zpool HDD, a 2x 4TB mirror) is imported at /hdd by this host —
  # either manually ("zpool import -f HDD") or declaratively once the VM has
  # the disks attached. The dataset mountpoints /hdd/Public, /hdd/Private and
  # /hdd/Dropbox become the shares below. Until the pool is attached these
  # paths do not exist and the shares simply list nothing.
  #
  # TODO (when the pool is attached):
  #   - decide SMB users (map to the pool's existing uid/gid owners)
  #   - macOS clients: enable the "fruit" vfs module for AAPL/streams support
  #   - decide the web UI (filebrowser / nextcloud / custom) and its port
  services.samba = {
    enable = true;
    openFirewall = true; # redundant while firewall-open.nix is imported; kept for clarity
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "NixOS file server";
        "map to guest" = "Never";
      };
      public = {
        path = "/hdd/Public";
        browseable = "yes";
        "read only" = "no";
        comment = "Public files from the HDD pool";
      };
      private = {
        path = "/hdd/Private";
        browseable = "no";
        "read only" = "no";
        comment = "Private files from the HDD pool";
      };
      dropbox = {
        path = "/hdd/Dropbox";
        browseable = "yes";
        "read only" = "no";
        comment = "Dropbox mirror from the HDD pool";
      };
    };
  };
}
