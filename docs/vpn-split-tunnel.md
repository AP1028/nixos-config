# Split-Tunnel VPN Setup (SJTU + Home OpenVPN, nested)

This document explains how the split-tunnel VPN setup works and how to set it
up on a new machine **without putting any secrets into the repository**.

## Concept

Two VPNs, connected in this order:

1. **Campus VPN (IKEv2/strongswan, split tunnel)** — routes *Chinese IPs*
   through the campus network (fast path for CN destinations). Everything else
   goes direct.
2. **Home VPN (OpenVPN, split tunnel)** — routes *only the home LAN*
   (e.g. `192.168.3.0/24`) through the home server. The OpenVPN endpoint
   itself rides *inside* the campus tunnel (the home server's public IP is a
   Chinese IP), so the path is:

   ```
   laptop → campus tunnel → internet → home server → home LAN
   ```

Both VPNs are **split tunnels**: no default route is ever taken over a tunnel.

## Secrets stay out of the repo

- VPN profiles are created **imperatively** with `nmcli` and live in
  `/etc/NetworkManager/system-connections/` (root-only `0600`), **not** in
  this repository.
- Credentials end up in exactly two places, both outside the repo:
  - the NetworkManager keyfiles (`[vpn-secrets]` section, plaintext by NM
    convention, root-only), and
  - the original `.ovpn` file you import (client key + tls-crypt live there).
- The repository only contains:
  - dispatcher scripts that reference **profile names** (no credentials), and
  - the home server's **DDNS hostname** (not a secret, and deliberately not a
    fixed IP so a changed dynamic IP needs no re-configuration).

## Setting up on a new machine

### 0. NixOS side

Include the module that installs the dispatcher scripts:

```nix
# in the host's module list
./modules/services/strongswan.nix
```

Rebuild (`nixos-rebuild switch --flake .#<host>`). This installs two
NetworkManager dispatcher scripts that run automatically on connect:

- on campus-VPN connect: drop charon-nm's forced full-tunnel default
  (routing table 210) and pin the home server's current IP into the campus
  tunnel (DDNS resolved at connect time);
- on home-VPN connect: same pin (covers a DDNS change while the campus VPN
  is already up).

The profile names and the DDNS hostname are the only per-site values; adjust
them in `modules/services/strongswan.nix` if your names differ.

### 1. Campus VPN profile (strongswan/IKEv2)

Create a NetworkManager VPN connection of type `strongswan` (EAP, your
campus username/password) — via the network applet or:

```bash
# create the connection; credentials are prompted for and stored by NM
nmcli connection add type vpn vpn-type strongswan con-name <campus-vpn> \
  vpn.data "address = <vpn-server>, method = eap, user = <username>, virtual = yes"
nmcli connection modify <campus-vpn> vpn.secrets "password = <prompted>"
```

Make it a **split tunnel** (Chinese IPs only):

```bash
nmcli connection modify <campus-vpn> \
  ipv4.never-default yes \
  ipv4.ignore-auto-dns yes \
  ipv6.ignore-auto-dns yes
# CN routes: any current China-IP list works, e.g. one generated from a
# GeoIP Country database (see notes below)
nmcli connection modify <campus-vpn> ipv4.routes "<cn-cidr-list>"
```

### 2. Home VPN profile (OpenVPN)

Import your provider's `.ovpn` (credentials stay inside that file):

```bash
nmcli connection import type openvpn file /path/to/your.ovpn
```

Then clone it and restrict the tunnel to the home LAN only:

```bash
nmcli connection clone <imported-name> <home-vpn>
nmcli connection modify <home-vpn> \
  ipv4.never-default yes \
  ipv4.ignore-auto-routes yes \
  ipv4.routes "192.168.3.0/24"   # your home LAN, adjust as needed
```

`ignore-auto-routes` drops the server-pushed `redirect-gateway`, so the
OpenVPN tunnel never takes the default route.

### 3. Connect (order matters)

The home VPN must be started **after** the campus VPN so its endpoint is
already routed into the campus tunnel:

```bash
nmcli connection up <campus-vpn>
nmcli connection up <home-vpn>
```

## Verifying the nesting

```bash
# home server endpoint must use the campus tunnel device (nm-xfrm-*)
ip route get <home-server-ip>

# home LAN must use the OpenVPN tunnel device (tun0)
ip route get 192.168.3.1

# conntrack shows the proof: the OpenVPN UDP flow is sourced from the
# campus virtual IP
sudo cat /proc/net/nf_conntrack | grep '<openvpn-port>'
```

## Troubleshooting

- **Everything routes through the campus tunnel**: charon-nm installs a
  full-tunnel default in its own routing table on connect; the dispatcher
  removes it within ~30 s (table 210). Check: `ip route show table 210`
  should be empty.
- **Home VPN endpoint goes direct**: NetworkManager pins the OpenVPN server's
  /32 via the physical device (loop protection). The dispatcher re-pins it
  into the campus tunnel with a lower metric. Check:
  `ip route get <home-server-ip>` — should show the `nm-xfrm-*` device.
- **DDNS IP changed**: nothing to do — the dispatchers resolve the hostname
  at every connect and re-pin the current IP.
- **Campus VPN drops on network blips**: enable auto-reconnect with
  `nmcli connection modify <campus-vpn> connection.autoconnect yes`.

## Generating the CN route list (notes)

Any current China-IP CIDR list works. This repo's tooling (in the
git-excluded `.dsh-cache/` directory) can generate one from a MaxMind
`Country.mmdb` using `libmaxminddb` (`mmdb_enum` walks the IPv4 subtree
and emits `CN` networks). Regenerate after updating the GeoIP database, then
re-apply with `nmcli connection modify <campus-vpn> ipv4.routes "$(paste -sd, list.txt)"`.

## Bilibili content access (SJTU only — not the OpenVPN path)

bilibili geo-DNS can hand out overseas CDN nodes (Akamai `148.153.x` /
`192.254.90.x`) even on a mainland network (resolver/browser-DoH dependent).
Those IPs are not in the CN list, so they would go direct and the region check
on `api.bilibili.com` would see the physical IP instead of the campus egress.

Fix (already applied on the campus split-tunnel profile): hardcode the
oversea CDN nodes into the campus tunnel:

```bash
for ip in 148.153.45.10 148.153.46.90 148.153.56.162 148.153.56.163 \
          148.153.64.18 192.254.90.178 192.254.90.179; do
  nmcli connection modify <campus-vpn> +ipv4.routes "$ip/32"
done
```

If bilibili starts serving new overseas IPs (check with
`getent ahostsv4 www.bilibili.com` and `ip route get <ip>`), add them the
same way.

**Scope note:** this override exists solely for the campus (CN) split tunnel
and content access. It does not affect the OpenVPN (home LAN) profile — that
tunnel only ever carries `192.168.3.0/24`.
