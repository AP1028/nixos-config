{inputs, pkgs, ...}: {
  # WinApps: run Windows applications from a KVM guest as if they were native
  environment.systemPackages = [
    inputs.winapps.packages."${pkgs.system}".winapps
    inputs.winapps.packages."${pkgs.system}".winapps-launcher
  ];
}
