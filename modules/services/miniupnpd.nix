# DISABLED: does not work for now
{
  config,
  pkgs,
  ...
}: {
  boot.kernelModules = ["ip_tables" "iptable_nat" "iptable_filter"];
  systemd.services.miniupnpd = {
    # Wait for the libvirt daemon to start handling networks
    after = ["libvirtd.service" "sys-subsystem-net-devices-virbr0.device"];
    requires = ["libvirtd.service"];

    # The '+' prefix runs this setup script with full root privileges,
    # bypassing the sandbox so it can load firewall kernel modules.
    serviceConfig.ExecStartPre = [
      "+${pkgs.writeShellScript "miniupnpd-setup" ''
        # 1. Force the kernel to load the legacy iptables nat and filter tables
        ${pkgs.iptables}/bin/iptables -t nat -L -n >/dev/null 2>&1 || true
        ${pkgs.iptables}/bin/iptables -t filter -L -n >/dev/null 2>&1 || true

        # 2. Wait up to 15 seconds for libvirtd to bring virbr0 fully UP
        for i in {1..15}; do
          if ${pkgs.iproute2}/bin/ip link show dev virbr0 | grep -q "UP"; then
            exit 0
          fi
          sleep 1
        done

        echo "ERROR: virbr0 did not come UP in time."
        exit 1
      ''}"
    ];
  };
  services.miniupnpd = {
    enable = true;

    # 1. Your host's physical Wi-Fi interface connected to the internet
    externalInterface = "wlan0";

    # 2. Tell the daemon to listen to requests originating inside libvirt
    internalIPs = ["virbr0"];

    # 3. Security best practices: Only allow UPnP mapping for local private IPs
    appendConfig = ''
      secure_mode=yes
      allow 1024-65535 192.168.122.0/24 1024-65535
      deny 0-65535 0.0.0.0/0 0-65535
    '';
  };
}
