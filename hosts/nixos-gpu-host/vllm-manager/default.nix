# vLLM model manager for nixos-gpu-host: web control panel (port 8500) +
# OpenAI-compatible API proxy (port 8000 -> vLLM backend on 127.0.0.1:8001).
#
# One stdlib-only Python process runs both listeners.  It starts/stops the
# vLLM-2080Ti-Definitive runtime (TP=2, FP8, MTP3, PIECEWISE CUDA graphs) for
# the models registered in models.json, exposes VRAM/health status and per-model
# log tails, and survives manager restarts by adopting a still-running backend.
#
# State (state.json) and backend logs live in /var/lib/vllm-manager (systemd
# StateDirectory, owned by tianyixia).  See README.md for the API and UI docs.
{
  config,
  lib,
  pkgs,
  ...
}: let
  appDir = pkgs.runCommandLocal "vllm-manager-app" {} ''
    mkdir -p "$out/web"
    cp ${./vllm-manager.py} "$out/vllm-manager.py"
    cp ${./models.json} "$out/models.json"
    cp ${./web/index.html} "$out/web/index.html"
    cp ${./web/app.js} "$out/web/app.js"
    cp ${./web/style.css} "$out/web/style.css"
  '';
in {
  networking.firewall.allowedTCPPorts = [8000 8500];

  systemd.services.vllm-manager = {
    description = "vLLM model manager + OpenAI API proxy (gpu-host)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "simple";
      User = "tianyixia";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${appDir}/vllm-manager.py";
      WorkingDirectory = "/var/lib/vllm-manager";
      StateDirectory = "vllm-manager";
      Restart = "always";
      RestartSec = 3;
      # Only signal the manager on stop/restart: the vLLM backend it spawned
      # must survive manager restarts (NixOS rebuilds) so the next instance
      # can adopt the still-running backend instead of reloading the model.
      KillMode = "process";
      Environment = ["VLLM_MANAGER_APP_DIR=${appDir}"];
    };
  };
}
