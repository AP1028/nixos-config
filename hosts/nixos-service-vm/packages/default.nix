{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    jdk21
    nodejs_22
  ];
}
