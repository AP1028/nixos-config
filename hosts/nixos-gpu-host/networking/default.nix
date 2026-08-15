{pkgs, ...}: {
  networking.hostName = "nixos-gpu-host";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  # Gigabit management NIC
  networking.interfaces.eno1.ipv4.addresses = [
    {
      address = "192.168.3.200";
      prefixLength = 24;
    }
  ];

  # 40G interconnect to pve (vmbr1, 10.0.0.1/24): jumbo frames + dedicated subnet
  networking.interfaces.enp133s0 = {
    mtu = 9000;
    ipv4.addresses = [
      {
        address = "10.0.0.200";
        prefixLength = 24;
      }
    ];
  };

  networking.defaultGateway = "192.168.3.1";
  networking.nameservers = ["192.168.3.1"];
}
