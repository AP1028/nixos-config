{
  pkgs,
  ...
}: {
  environment.systemPackages = with pkgs; [
    (pkgs.writeShellScriptBin "parsec-iptables-on" ''
      iptables -t nat -I PREROUTING 1 -i wlan0 -p udp --dport 8000:8010 -j DNAT --to-destination 192.168.122.53
      iptables -I FORWARD 1 -i wlan0 -o virbr0 -p udp -d 192.168.122.53 --dport 8000:8010 -j ACCEPT
      iptables -t nat -I POSTROUTING 1 -s 192.168.3.0/24 -d 192.168.122.53 -p udp --dport 8000:8010 -j MASQUERADE
      iptables -t nat -I POSTROUTING 1 -s 192.168.122.53 -p udp --sport 8000:8010 -j MASQUERADE --to-ports 8000-8010
    '')
    (pkgs.writeShellScriptBin "parsec-iptables-off" ''
      iptables -t nat -D PREROUTING -i wlan0 -p udp --dport 8000:8010 -j DNAT --to-destination 192.168.122.53 2>/dev/null
      iptables -D FORWARD -i wlan0 -o virbr0 -p udp -d 192.168.122.53 --dport 8000:8010 -j ACCEPT 2>/dev/null
      iptables -t nat -D POSTROUTING -s 192.168.3.0/24 -d 192.168.122.53 -p udp --dport 8000:8010 -j MASQUERADE 2>/dev/null
      iptables -t nat -D POSTROUTING -s 192.168.122.53 -p udp --sport 8000:8010 -j MASQUERADE --to-ports 8000-8010 2>/dev/null
    '')
  ];
}
