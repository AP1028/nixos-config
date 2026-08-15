{pkgs, ...}: {
  networking.hostName = "nixos-gpu-host";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  # The old 7700k machine used enp3s0. Adjust this to the physical NIC name
  # after first boot if the replacement hardware differs.
  networking.interfaces.enp3s0.ipv4.addresses = [
    {
      address = "192.168.3.200";
      prefixLength = 24;
    }
  ];

  networking.defaultGateway = "192.168.3.1";
  networking.nameservers = ["192.168.3.1"];
}
