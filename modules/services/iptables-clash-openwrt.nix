{ interface }:

{
  config,
  lib,
  pkgs,
  ...
}: {
  networking.iproute2.enable = true;

  systemd.services.custom-routing-table = {
    description = "Set up routing table 100 for OpenWRT bypass";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.iproute2}/bin/ip route replace default via 192.168.3.1 table 100
      if ! ${pkgs.iproute2}/bin/ip rule show | grep -q "fwmark 0x1 lookup 100"; then
        ${pkgs.iproute2}/bin/ip rule add fwmark 0x1 table 100
      fi
    '';
  };

  networking.firewall.extraCommands = ''
    iptables -t mangle -A OUTPUT -m mark --mark 0xd2 -j RETURN
    iptables -t mangle -A PREROUTING -m connmark --mark 0x1 -j CONNMARK --restore-mark
    iptables -t mangle -A PREROUTING -m mac --mac-source 28:48:e7:ee:d5:42 -j MARK --set-mark 0x1
    iptables -t mangle -A PREROUTING -m mark --mark 0x1 -j CONNMARK --save-mark
    iptables -t mangle -A OUTPUT -m connmark --mark 0x1 -j CONNMARK --restore-mark
  '';

  boot.kernel.sysctl = lib.mkDefault {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    "net.ipv4.conf.${interface}.rp_filter" = 2;
  };
}
