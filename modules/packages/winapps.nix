{inputs, pkgs, ...}: {
  # WinApps: run Windows applications from a KVM guest as if they were native
  environment.systemPackages = [
    inputs.winapps.packages."${pkgs.stdenv.hostPlatform.system}".winapps
    inputs.winapps.packages."${pkgs.stdenv.hostPlatform.system}".winapps-launcher
  ];
}
