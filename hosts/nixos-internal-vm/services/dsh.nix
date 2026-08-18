{
  config,
  lib,
  pkgs,
  ...
}: let
  dsh = pkgs.callPackage ../../../packages/deepseek-harness { };
in {
  environment.systemPackages = [dsh];

  # DeepSeek Harness web UI runs as the normal user tianyixia so sandboxed
  # commands, profiles, credentials, and file access use the user's real
  # home/permissions. nginx (services/nginx.nix) reverse-proxies it as HTTPS
  # on :8080.
  #
  # --trusted-host teaches dsh's /api browser-trust fence to accept the LAN
  # host/port it is reached through via nginx.
  systemd.services.dsh-web = {
    description = "DeepSeek Harness web UI";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    # Put the whole host system PATH inside the dsh service, so sandboxed
    # commands see the same tools as an interactive shell (curl, wget, git,
    # node, bash, etc.).
    path = [
      "/run/current-system/sw"
    ];
    serviceConfig = {
      Type = "simple";
      User = "tianyixia";
      Group = "users";
      Environment = "DSH_HOME=/home/tianyixia/.dsh";
      ExecStart = "${dsh}/bin/dsh web --host 127.0.0.1 --port 3080 --trusted-host 192.168.3.105 --trusted-host nixos-internal-vm";
      Restart = "on-failure";
    };
  };

  # dsh's PTY shell defaults to /bin/bash, but NixOS does not provide that
  # path. Provide it as a symlink to the system bash.
  systemd.tmpfiles.rules = [
    "L+ /bin/bash - - - - /run/current-system/sw/bin/bash"
  ];
}
