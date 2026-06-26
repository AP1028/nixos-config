{config, pkgs, ...}: let
  sudo-env = pkgs.writeShellScriptBin "sudo-env" ''
    exec sudo -u "''${SUDO_USER:-$USER}" -E zsh "$@"
  '';
in {
  environment.systemPackages = [sudo-env];

  security.sudo.extraRules = [
    {
      users = [config.local.username];
      runAs = "ALL";
      commands = [
        {
          command = "${sudo-env}/bin/sudo-env";
          options = ["NOPASSWD" "SETENV"];
        }
        {
          command = "/run/current-system/sw/bin/sudo-env";
          options = ["NOPASSWD" "SETENV"];
        }
      ];
    }
  ];
}
