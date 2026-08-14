{pkgs, ...}: {
  imports = [
    ../../../modules/packages/opencode.nix
  ];

  # Gitea machine: hardware toolchain (riscv gcc / verilator) stripped out.
  environment.systemPackages = with pkgs; [
    python3
  ];
}
