{pkgs, ...}: {
  imports = [
    ./default.nix
    ../../system/sudo-env.nix
    ../../packages/opencode.nix
  ];

  sudoEnv.headless = true;

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
