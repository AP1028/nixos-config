{
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    bilibili
    firefox
    moonlight-qt
    openvpn

    (python3.withPackages (ps: [ps.numpy]))
  ];
}
