{pkgs, ...}: {
  networking.hostName = "nixos-git-vm";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = "192.168.3.102";
      prefixLength = 24;
    }
  ];

  networking.defaultGateway = "192.168.3.1";
  networking.nameservers = ["192.168.3.1"];
}
