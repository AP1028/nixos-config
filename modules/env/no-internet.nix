{
  config,
  lib,
  pkgs,
  ...
}: {
  users.groups.no-internet = {};
  users.users.${config.local.username}.extraGroups = ["no-internet" "video" "render"];

  networking.firewall.extraCommands = ''
    iptables -D OUTPUT -m owner --gid-owner no-internet -j no-internet-out 2>/dev/null || true
    iptables -F no-internet-out 2>/dev/null || true
    iptables -X no-internet-out 2>/dev/null || true

    iptables -N no-internet-out
    iptables -A no-internet-out -o lo -p tcp --dport 7890:7899 -j REJECT
    iptables -A no-internet-out -o lo -p tcp --dport 1080 -j REJECT
    iptables -A no-internet-out -o lo -j ACCEPT
    iptables -A no-internet-out -j REJECT --reject-with icmp-port-unreachable

    iptables -I OUTPUT 1 -m owner --gid-owner no-internet -j no-internet-out

    ip6tables -D OUTPUT -m owner --gid-owner no-internet -j no-internet-out6 2>/dev/null || true
    ip6tables -F no-internet-out6 2>/dev/null || true
    ip6tables -X no-internet-out6 2>/dev/null || true

    ip6tables -N no-internet-out6
    ip6tables -A no-internet-out6 -o lo -p tcp --dport 7890:7899 -j REJECT
    ip6tables -A no-internet-out6 -o lo -j ACCEPT
    ip6tables -A no-internet-out6 -j REJECT --reject-with icmp6-port-unreachable

    ip6tables -I OUTPUT 1 -m owner --gid-owner no-internet -j no-internet-out6
  '';
}
