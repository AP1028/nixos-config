# llama.cpp RPC setup for the two AMD GPUs using the Vulkan (RADV) backend.
#
# This machine acts as a GPU worker: a single rpc-server exposes both GPUs
# (plus the host CPU as a last-resort memory device) that remote llama-server
# clients connect to via --rpc. The local llama-server option is only for
# testing the combined setup. Everything is opt-in via services.llamaRpc.enable.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.llamaRpc;

  llama = pkgs.callPackage ../../packages/llama-cpp-rpc.nix { };
in
{
  options.services.llamaRpc = {
    enable = lib.mkEnableOption "llama.cpp RPC server (Vulkan) for the AMD GPUs";

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to bind the RPC server to.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 50052;
      description = "Port of the RPC server.";
    };
    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Devices to expose, in order (e.g. Vulkan1,Vulkan0,CPU). Empty = all non-CPU devices.";
    };
    threads = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Number of threads for the CPU device.";
    };

    llamaServer = {
      enable = lib.mkEnableOption "llama-server (loads the model, talks to the RPC server)";

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
    hardware.graphics.enable = true; # RADV ICDs for the Vulkan backend

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.services.llama-rpc = {
      description = "llama.cpp RPC server - AMD RX 560 / RX 5600XT (Vulkan)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${llama}/bin/llama-rpc-server \
            -H ${cfg.host} -p ${toString cfg.port} \
            -t ${toString cfg.threads} \
            ${lib.optionalString (cfg.devices != [ ]) "-d ${lib.concatStringsSep "," cfg.devices}"}
        '';
        Environment = [
          "VK_ICD_DIRS=/run/opengl-driver/share/vulkan/icd.d"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.llama-server = lib.mkIf cfg.llamaServer.enable {
      description = "llama.cpp server (RPC to the AMD GPUs)";
      wantedBy = [ "multi-user.target" ];
      after = [ "llama-rpc.service" ];
      requires = [ "llama-rpc.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${llama}/bin/llama-server \
            --host ${cfg.llamaServer.host} --port ${toString cfg.llamaServer.port} \
            --rpc 127.0.0.1:${toString cfg.port} \
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
