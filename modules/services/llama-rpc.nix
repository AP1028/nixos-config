# llama.cpp RPC setup for the two AMD GPUs using ROCm 5.7.1 (from the pinned
# nixos-23-11 input, since ROCm >= 6 dropped gfx803 / the RX 560).
#
# This machine acts as a GPU worker: each GPU gets its own rpc-server (a
# "cluster") that remote llama-server clients connect to via --rpc. The
# local llama-server option is only for testing the combined setup.
# Everything is opt-in via services.llamaRpc.enable.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.services.llamaRpc;

  oldPkgs = import inputs.nixos-23-11 {
    localSystem = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  rocm = import ../../packages/rocm-570.nix { inherit oldPkgs; };

  llama = oldPkgs.callPackage ../../packages/llama-cpp-rpc.nix {
    rocmPackages = rocm;
  };
in
{
  options.services.llamaRpc = {
    enable = lib.mkEnableOption "llama.cpp RPC servers (ROCm 5.7) for the AMD GPUs";

    rx560Device = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "HIP device index of the Radeon RX 560 (Baffin, gfx803).";
    };
    rx5700Device = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "HIP device index of the Radeon RX 5700 (Navi 10, gfx1010).";
    };
    rx560Port = lib.mkOption {
      type = lib.types.port;
      default = 50052;
      description = "Port of the RX 560 RPC server.";
    };
    rx5700Port = lib.mkOption {
      type = lib.types.port;
      default = 50053;
      description = "Port of the RX 5700 RPC server.";
    };

    llamaServer = {
      enable = lib.mkEnableOption "llama-server (loads the model, talks to both RPC servers)";

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
      };
      modelPath = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/llama/models/model.gguf";
        description = "GGUF model to serve.";
      };
      gpuLayers = lib.mkOption {
        type = lib.types.int;
        default = 99;
        description = "Layers to offload to the GPUs (-ngl).";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments passed to llama-server.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.llama-rpc-rx560 = {
      description = "llama.cpp RPC server - AMD RX 560 (gfx803, ROCm 5.7)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${llama}/bin/rpc-server --host 127.0.0.1 --port ${toString cfg.rx560Port}";
        Environment = [
          "HIP_VISIBLE_DEVICES=${toString cfg.rx560Device}"
          "ROCR_VISIBLE_DEVICES=${toString cfg.rx560Device}"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.llama-rpc-rx5700 = {
      description = "llama.cpp RPC server - AMD RX 5700 (gfx1010, ROCm 5.7)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${llama}/bin/rpc-server --host 127.0.0.1 --port ${toString cfg.rx5700Port}";
        Environment = [
          "HIP_VISIBLE_DEVICES=${toString cfg.rx5700Device}"
          "ROCR_VISIBLE_DEVICES=${toString cfg.rx5700Device}"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.llama-server = lib.mkIf cfg.llamaServer.enable {
      description = "llama.cpp server (RPC to both AMD GPUs)";
      wantedBy = [ "multi-user.target" ];
      after = [ "llama-rpc-rx560.service" "llama-rpc-rx5700.service" ];
      requires = [ "llama-rpc-rx560.service" "llama-rpc-rx5700.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${llama}/bin/llama-server \
            --host ${cfg.llamaServer.host} --port ${toString cfg.llamaServer.port} \
            --rpc 127.0.0.1:${toString cfg.rx560Port},127.0.0.1:${toString cfg.rx5700Port} \
            --model ${cfg.llamaServer.modelPath} \
            --n-gpu-layers ${toString cfg.llamaServer.gpuLayers} \
            ${lib.escapeShellArgs cfg.llamaServer.extraArgs}
        '';
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.llamaServer.enable [
      "d /var/lib/llama/models 0755 root root -"
    ];
  };
}
