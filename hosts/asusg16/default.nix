{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./kernel
    ./networking
    ./packages
    ./system

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "asusg16"; })

    ./hardware/nvme-vfio.nix
    ./hardware/scripts.nix

    ../../modules/hardware/nvidia.nix
    ../../modules/hardware/i915-sriov.nix
    ../../modules/hardware/secureboot.nix
    ../../modules/hardware/asusctl.nix
    ../../modules/hardware/virtualization.nix
    ../../modules/hardware/bridge.nix
    ../../modules/hardware/common.nix
    ../../modules/hardware/flydigi.nix

    ../../modules/desktop
    ../../modules/system/i18n.nix

    ../../modules/services/audio.nix
    ../../modules/services/clash-verge.nix
    ../../modules/services/sunshine.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix
    (import ../../modules/services/iptables-clash-openwrt.nix { interface = "wlan0"; })
    ../../modules/services/iptables-parsec-vm.nix
    ../../modules/services/vscode-server.nix
    ../../modules/services/strongswan.nix
    ../../modules/services/samba.nix

    ./users

    ../../modules/env/xilinx-env.nix
    ../../modules/env/synopsys-env.nix
    ../../modules/env/matlab-env.nix
    ../../modules/env/game-env.nix
    ../../modules/env/common.nix
    ../../modules/env/no-internet.nix
    ../../modules/env/sudo-env.nix
  ];

  home-manager.users.${config.local.username} = {
    imports = [ ../../modules/home ];
  };
}
