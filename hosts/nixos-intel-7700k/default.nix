{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  home-manager.users.${config.local.username}.local.home.fastfetch.enable = false;

  imports = [
    ./hardware-configuration.nix
    ./networking
    ./system
    ./packages
    ./desktop
    ./users

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-intel-7700k"; })

    ../../modules/system/i18n.nix
    ../../modules/system/substituters.nix
    ../../modules/system/sudo-env.nix

    ../../modules/hardware/common.nix

    ../../modules/services/audio.nix
    ../../modules/services/openssh.nix
    ../../modules/services/vscode-server.nix
    # RPC server services for the AMD GPUs; opt-in via services.llamaRpc.enable
    ../../modules/services/llama-rpc.nix
  ];

  services.llamaRpc = {
    enable = true;
    # Fill order for the cluster: RX 5600XT first, then RX 560, then host RAM.
    # Vulkan0 is the Intel iGPU and must NOT be exposed.
    devices = [ "Vulkan2" "Vulkan1" "CPU" ];
    threads = 8;
  };
}
