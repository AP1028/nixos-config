{
  config,
  lib,
  pkgs,
  ...
}: {
  # ── StrongSwan IPsec VPN via NetworkManager ─────────────────────

  networking.networkmanager.plugins = with pkgs; [
    networkmanager-strongswan
  ];

  # Pass CA cert path to the NetworkManager StrongSwan plugin
  systemd.services.NetworkManager.environment = {
    STRONGSWAN_CONF = pkgs.writeTextFile {
      name = "strongswan.conf";
      text = ''
        charon-nm {
          ca_dir = ${pkgs.cacert.unbundled}/etc/ssl/certs
        }
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    strongswan # swanctl and ipsec command-line tools
  ];

  # Split-tunnel support for the SJTU_splittunnel NM profile (charon-nm).
  #
  # charon-nm creates an XFRM interface (nm-xfrm-*) and, regardless of the
  # profile's ipv4.never-default, installs a full-tunnel default route in its
  # own routing table (210, matching its fwmark 0xd2). The profile routes all
  # CN subnets into the xfrm device via the main table, so on connect we drop
  # that table-210 default: Chinese traffic keeps using the tunnel while
  # everything else falls through to the physical default route.
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "nm-strongswan-split-tunnel" ''
        if [ "$CONNECTION_ID" = "SJTU_splittunnel" ] && { [ "$2" = "vpn-up" ] || [ "$2" = "up" ]; }; then
          iface="''${VPN_IP_IFACE:-}"
          if [ -z "$iface" ]; then
            iface=$(ip -o link show type xfrm 2>/dev/null | head -1 | sed -E 's/^[0-9]+: ([^:@]+).*/\1/')
          fi
          [ -n "$iface" ] || exit 0
          # charon-nm puts a full-tunnel default in table 210 at connect time
          # and re-adds it once while its setup settles; keep removing it
          # until it has stayed away (~20 s), capped at 3 minutes.
          stable=0
          end=$((SECONDS + 180))
          while [ "$SECONDS" -lt "$end" ]; do
            if ip route show table 210 2>/dev/null | grep -q '^default'; then
              ip route del default dev "$iface" table 210 2>/dev/null || ip route del default table 210 2>/dev/null || true
              stable=0
            else
              stable=$((stable + 1))
              if [ "$stable" -ge 10 ]; then
                break
              fi
            fi
            sleep 2
          done

          # Nest openvpn-cn-splittunnel: NM pins the (DDNS) home-server address
          # as a /32 via the physical device; pin it into this xfrm device with
          # a low metric instead so the OpenVPN endpoint rides this tunnel.
          i=0
          while [ "$i" -lt 5 ]; do
            for ip in $(${pkgs.getent}/bin/getent ahostsv4 homeserver040322.ddns.net 2>/dev/null | sed -E 's/[[:space:]].*//' | sort -u); do
              ip route replace "$ip/32" dev "$iface" metric 5 2>/dev/null || true
            done
            sleep 1
            i=$((i + 1))
          done
        fi
      '';
      type = "basic";
    }

    {
      source = pkgs.writeShellScript "nm-openvpn-nest" ''
        # Nest openvpn-cn-splittunnel inside SJTU_splittunnel. NM pins the
        # OpenVPN server's address as a /32 via the physical device (loop
        # protection). If the SJTU tunnel is up, re-pin it into the xfrm
        # device with a low metric instead, so the endpoint rides the SJTU
        # tunnel. The server is behind DDNS, so resolve it at connect time
        # (covers DDNS changes without touching the profile).
        if [ "$CONNECTION_ID" = "openvpn-cn-splittunnel" ] && [ "$2" = "vpn-up" ]; then
          iface=$(ip -o link show type xfrm 2>/dev/null | head -1 | sed -E 's/^[0-9]+: ([^:@]+).*/\1/')
          [ -n "$iface" ] || exit 0
          i=0
          while [ "$i" -lt 5 ]; do
            for ip in $(${pkgs.getent}/bin/getent ahostsv4 homeserver040322.ddns.net 2>/dev/null | sed -E 's/[[:space:]].*//' | sort -u); do
              ip route replace "$ip/32" dev "$iface" metric 5 2>/dev/null || true
            done
            sleep 1
            i=$((i + 1))
          done
        fi
      '';
      type = "basic";
    }
  ];

  # Override the empty strongswan.conf that the strongswan package ships by default
  environment.etc."strongswan.conf".text = "";

  # Disable strict reverse‑path filtering (VPN traffic may arrive on unexpected interface)
  networking.firewall.checkReversePath = false;

  boot.kernel.sysctl = lib.mkDefault {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };
}
