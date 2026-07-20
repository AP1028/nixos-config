{pkgs, ...}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  environment.systemPackages = with pkgs; [
    pkgsCross.riscv32-embedded.buildPackages.gcc
    verilator
    python3
  ];
}
