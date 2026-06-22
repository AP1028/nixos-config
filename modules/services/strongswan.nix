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

  # Override the empty strongswan.conf that the strongswan package ships by default
  environment.etc."strongswan.conf".text = "";

  # Disable strict reverse‑path filtering (VPN traffic may arrive on unexpected interface)
  networking.firewall.checkReversePath = false;

  boot.kernel.sysctl = lib.mkDefault {
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };
}
