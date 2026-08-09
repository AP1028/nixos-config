{
  pkgs,
  ...
}: {
  networking.hostName = "nixos-intel-7700k";
  networking.networkmanager.enable = false;

  networking.useDHCP = false;
  networking.interfaces.enp3s0.useDHCP = false;
  networking.interfaces.enp3s0.ipv4.addresses = [
    {
      address = "192.168.3.200";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.3.1";
  networking.nameservers = ["192.168.3.1"];
}
