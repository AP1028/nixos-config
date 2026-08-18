{pkgs, ...}: {
  # Internal services VM: keep it lean; services live in ./services.
  environment.systemPackages = with pkgs; [
    # handy for poking at the dsh web endpoint / services
    curl
    # provides htpasswd for imperatively managing the dsh nginx basic-auth file
    apacheHttpd
    # expose node to dsh's sandboxed shell so sandbox commands can use it
    nodejs
  ];
}
