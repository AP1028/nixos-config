{ pkgs, lib, ... }: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    (pkgs.callPackage ../../../packages/ysm-java { })
    nodejs_22
    screen
  ];

  programs.java = {
    enable = true;
    package = pkgs.callPackage ../../../packages/ysm-java { };
  };
}
