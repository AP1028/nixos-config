{pkgs, ...}: {
  networking.hostName = "nixos-gpu-vm";
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  # Gigabit management NIC — takes over the old gpu-host LAN identity
  # (192.168.3.200), so all service URLs/certs that referenced the bare-metal
  # host stay valid.
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = "192.168.3.200";
      prefixLength = 24;
    }
  ];

  # 40G bridge (vmbr1) on the Proxmox host: jumbo frames + dedicated subnet.
  # 10.0.0.200 was the old bare-metal gpu-host's interconnect address; the
  # P40/RPC cluster it served is retired, but the 40G link stays for the
  # remaining LAN traffic patterns.
  networking.interfaces.ens19 = {
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
