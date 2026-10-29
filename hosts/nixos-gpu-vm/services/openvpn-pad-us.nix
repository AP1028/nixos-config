{pkgs, ...}: {
  systemd.services.pad-us-splittunnel = {
    description = "OpenVPN client for the pad-us split tunnel";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.openvpn}/sbin/openvpn --config /etc/openvpn/pad-us-splittunnel.ovpn";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
