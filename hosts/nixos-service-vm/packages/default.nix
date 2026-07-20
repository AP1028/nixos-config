{ pkgs, lib, ... }: {
  environment.systemPackages = with pkgs; [
    (pkgs.callPackage ../../../packages/ysm-java { })
    nodejs_22
  ];

  programs.java = {
    enable = true;
    package = pkgs.callPackage ../../../packages/ysm-java { };
  };
}
