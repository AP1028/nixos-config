{
  config,
  lib,
  pkgs,
  ...
}: {
  networking.wireguard.interfaces.wg0 = {
    privateKeyFile = "/etc/wireguard/private.key";
    listenPort = 57844;
    ips = ["10.7.0.1/24"];
    peers = [
      {
        publicKey = "3vmb6lJwiHUlgjv/9pLBgdcmM7nf0BzoQbwr40QeKFs=";
        presharedKeyFile = "/etc/wireguard/psk-client_home";
        allowedIPs = ["10.7.0.2/32"];
      }
      {
        publicKey = "p8lyzreTKNiLuzNXsLySGyBJiq5ay0Nxn8Y7iWXdCGQ=";
        presharedKeyFile = "/etc/wireguard/psk-home_phone";
        allowedIPs = ["10.7.0.3/32"];
      }
      {
        publicKey = "4wTRQFe2QWwb//nL6NILuYz8Tqii1a9fiGu2jTpSxDg=";
        presharedKeyFile = "/etc/wireguard/psk-home_pad";
        allowedIPs = ["10.7.0.4/32"];
      }
    ];
  };

  networking.nat = {
    enable = true;
    internalIPs = ["10.7.0.0/24" "10.8.0.0/24"];
    externalInterface = "ens18";
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
}
