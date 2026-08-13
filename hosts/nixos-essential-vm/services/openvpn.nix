{
  config,
  lib,
  pkgs,
  ...
}: {
  systemd.tmpfiles.rules = [
    "d /var/log/openvpn 0750 root root -"
    "d /etc/openvpn/ccd 0750 root root -"
  ];

  services.openvpn.servers.essential = {
    config = ''
      port 57845
      proto udp
      dev tun
      user nobody
      group nogroup
      persist-key
      persist-tun
      keepalive 10 120
      topology subnet
      server 10.8.0.0 255.255.255.0
      ifconfig-pool-persist /etc/openvpn/ipp.txt
      push "dhcp-option DNS 223.6.6.6"
      push "dhcp-option DNS 114.114.114.114"
      push "redirect-gateway def1 bypass-dhcp"
      dh none
      ecdh-curve prime256v1
      tls-crypt /etc/openvpn/tls-crypt.key
      crl-verify /etc/openvpn/crl.pem
      ca /etc/openvpn/ca.crt
      cert /etc/openvpn/server_L85tLRd8On9vVAce.crt
      key /etc/openvpn/server_L85tLRd8On9vVAce.key
      auth SHA256
      cipher AES-128-GCM
      ncp-ciphers AES-128-GCM
      tls-server
      tls-version-min 1.2
      tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
      client-config-dir /etc/openvpn/ccd
      status /var/log/openvpn/status.log
      verb 3
    '';
  };
}
