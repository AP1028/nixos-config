{
  pkgs,
  ...
}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    (python3.withPackages (ps: [ps.numpy]))
  ];
}
