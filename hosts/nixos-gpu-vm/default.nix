{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./networking

    ../../modules/system/vm-base.nix
    (import ../../modules/system/i18n.nix {})
    ../../modules/system/substituters.nix

    ../../modules/system/local.nix
    (import ../../modules/system/rebuild-scripts.nix { host = "nixos-gpu-vm"; })

    ../../modules/users/main-user.nix

    ../../modules/hardware/common.nix
    ../../modules/packages/common/vm-common.nix

    ../../modules/services/vscode-server.nix
    ../../modules/services/openssh.nix
    ../../modules/services/firewall-open.nix

    ./gpu.nix
    ./comfyui.nix
    ./vllm-qwen
    ./vllm-manager

    ./packages
  ];

  # nixpkgs added its own `services.comfyui` module (2026-08); the comfyui-nix
  # flake module declares the same option, so keep only comfyui-nix's.
  disabledModules = [ "services/misc/comfyui.nix" ];
}
