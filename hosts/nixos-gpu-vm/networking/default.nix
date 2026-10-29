{pkgs, ...}: {
  networking.hostName = "nixos-gpu-vm";
  networking.networkmanager = {
    enable = true;
    plugins = [pkgs.networkmanager-openvpn];
    ensureProfiles.profiles = {
      ens18 = {
        connection = {
          id = "ens18";
          type = "ethernet";
          interface-name = "ens18";
          autoconnect = "true";
        };
        ipv4 = {
          method = "manual";
          addresses = "192.168.3.200/24";
          gateway = "192.168.3.1";
          dns = "192.168.3.1";
        };
        ipv6.method = "ignore";
      };
      ens19 = {
        connection = {
          id = "ens19";
          type = "ethernet";
          interface-name = "ens19";
          autoconnect = "true";
        };
        ethernet.mtu = 9000;
        ipv4 = {
          method = "manual";
          addresses = "10.0.0.200/24";
          never-default = "true";
        };
        ipv6.method = "ignore";
      };
    };
  };
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
