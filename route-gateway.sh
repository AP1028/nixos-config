#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Must be run as root. Usage: sudo $0" >&2
  exit 1
fi

GW="${1:-192.168.3.2}"
STATE_FILE="/tmp/route-gateway-state"

# Use default interface (the one with the current default route, or the first active one)
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
  IFACE=$(ip -o link show up | grep -v lo | head -1 | awk -F': ' '{print $2}')
fi

if [ -z "$IFACE" ]; then
  echo "No active interface found." >&2
  exit 1
fi

# Save current DNS
cp /etc/resolv.conf "$STATE_FILE.dns"

# Save current default route
ip route show default > "$STATE_FILE.route" 2>/dev/null || true

# Apply overrides
echo "nameserver $GW" > /etc/resolv.conf
if ip route show default &>/dev/null; then
  ip route replace default via "$GW" dev "$IFACE"
else
  ip route add default via "$GW" dev "$IFACE"
fi

echo "Gateway → $GW (interface: $IFACE), DNS → $GW"
