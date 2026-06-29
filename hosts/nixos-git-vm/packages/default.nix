{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    pkgsCross.riscv32-embedded.buildPackages.gcc
    verilator
    python3
  ];
}
