{pkgs, ...}: {
  networking.hostName = "nixos-file-vm";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = "192.168.3.104";
      prefixLength = 24;
    }
  ];

  # 40G bridge (vmbr1) on the Proxmox host: jumbo frames + dedicated subnet.
  # Still faster than gigabit even at the x4 PCIe ceiling (~31 Gb/s).
  networking.interfaces.ens19 = {
    mtu = 9000;
    ipv4.addresses = [
      {
        address = "10.0.0.104";
        prefixLength = 24;
      }
    ];
  };

  networking.defaultGateway = "192.168.3.1";
  networking.nameservers = ["192.168.3.1"];
}
