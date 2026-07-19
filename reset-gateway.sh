#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

STATE_FILE="/tmp/route-gateway-state"

# Restore DNS
if [ -f "$STATE_FILE.dns" ]; then
  cp "$STATE_FILE.dns" /etc/resolv.conf
  rm "$STATE_FILE.dns"
else
  echo "No saved DNS state found." >&2
fi

# Restore default route
ip route del default 2>/dev/null || true
if [ -f "$STATE_FILE.route" ]; then
  while read -r route; do
    if [ -n "$route" ]; then
      ip route add $route 2>/dev/null || true
    fi
  done < "$STATE_FILE.route"
  rm "$STATE_FILE.route"
else
  echo "No saved route state found." >&2
fi

echo "Gateway and DNS restored."
