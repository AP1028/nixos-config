{pkgs, ...}: {
  imports = [
    ./default.nix
  ];

  environment.systemPackages = with pkgs; [
    distrobox
    steam-run
    net-tools
    neovim
    nixd
    alejandra
    gcc
    clang
    tmux
    graalvmPackages.graalvm-ce
  ];
}
