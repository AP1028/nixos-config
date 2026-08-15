{pkgs, ...}: {
  # Internal services VM: keep it lean; services live in ./services.
  environment.systemPackages = with pkgs; [
    # handy for poking at the dsh web endpoint / services
    curl
  ];
}
