# LAN vLLM stack self-signed PUBLIC certificates, installed into the system
# trust store so browsers, curl, and NixOS tools that read the system CA
# bundle accept the endpoints without warnings:
#   * nixos-webapp-vm  (homeserver040322.ddns.net:18081, 192.168.3.152)
#   * nixos-gpu-host   (192.168.3.200:8000/8001)
#
# These are public certificates only - no private keys. Node-based tools
# (DSH, SillyTavern) additionally need NODE_EXTRA_CA_CERTS because Node
# ignores the system store; see modules/home/zsh and the internal-vm
# services for those.
{
  config,
  ...
}: {
  security.pki.certificates = [
    (builtins.readFile ./certs/webapp-vm.crt)
    (builtins.readFile ./certs/gpu-host.crt)
  ];
}
