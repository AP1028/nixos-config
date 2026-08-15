{
  config,
  lib,
  pkgs,
  ...
}: let
  dsh = pkgs.callPackage ../../../packages/deepseek-harness { };
in {
  environment.systemPackages = [dsh];

  # DeepSeek Harness web UI, bound to localhost only; nginx (services/nginx.nix)
  # reverse-proxies it to the network. DSH_HOME holds profiles/config.
  systemd.services.dsh-web = {
    description = "DeepSeek Harness web UI";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "simple";
      User = "service";
      StateDirectory = "dsh";
      Environment = "DSH_HOME=/var/lib/dsh";
      ExecStart = "${dsh}/bin/dsh web --host 127.0.0.1 --port 3080";
      Restart = "on-failure";
    };
  };
}
