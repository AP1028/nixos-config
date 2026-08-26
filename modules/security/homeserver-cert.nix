# homeserver040322.ddns.net self-signed certificate, installed into the
# system trust store so browsers, curl, and NixOS tools accept the endpoint
# without warnings.
#
# The certificate file lives in git-excluded/ (gitignored) and is read at
# eval time from /etc/nixos (a symlink to ~/nixos-config on this machine),
# mirroring the git-excluded/fonts pattern in modules/desktop/fonts.nix.
{
  config,
  lib,
  ...
}: let
  certPath = /etc/nixos/git-excluded/certs/homeserver040322.ddns.net.crt;
in {
  security.pki.certificates =
    if builtins.pathExists certPath
    then [ (builtins.readFile certPath) ]
    else
      lib.warn
      "homeserver040322.ddns.net certificate missing at ${certPath}; not added to trust store"
      [];
}
