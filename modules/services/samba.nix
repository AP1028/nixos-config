{
  config,
  lib,
  pkgs,
  ...
}: {
  # ── Samba file share for KVM guests ─────────────────────────────
  # Exposes the main user's home directory as a network share reachable only by VMs on virbr0

  services.samba = {
    enable = true;
    openFirewall = true; # restricted to virbr0 + lo by interfaces setting

    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "NixOS KVM Samba";
        "netbios name" = "nixos-host";
        "security" = "user";
        "interfaces" = "virbr0 127.0.0.1";
        "bind interfaces only" = "yes";
        "hosts allow" = "192.168.122.0/24 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
      };

      "home" = {
        "path" = "/home/${config.local.username}";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = config.local.username;
      };
    };
  };

  # # Firewall: Open Samba ports ONLY on the KVM virtual interface
  # # Keep this for self-contained purpose
  # networking.firewall.interfaces.virbr0 = {
  #   allowedTCPPorts = [139 445];
  #   allowedUDPPorts = [137 138];
  # };
}
