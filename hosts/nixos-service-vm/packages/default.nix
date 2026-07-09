{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    temurin-bin-21
    nodejs_22
  ];

  programs.java = {
    enable = true;
    package = pkgs.temurin-bin-21;
  };
}
