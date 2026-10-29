{
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    moonlight-qt

    (python3.withPackages (ps: [ps.numpy]))
  ];
}
