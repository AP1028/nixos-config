# vLLM model manager (nixos-gpu-host)

One stdlib-only Python service that turns the GPU host into a remote model
control box:

* **Control panel (web UI + management API)** — http://192.168.3.200:8500/
  * choose which model runs (start / stop / switch)
  * live VRAM report per GPU (via nvidia-smi) and host RAM
  * backend health, uptime, per-model log tails
* **OpenAI-compatible API proxy** — http://192.168.3.200:8000/v1
  * every request is streamed through to the vLLM backend
    (chat/completions, completions, models, /docs, ...)
  * 503 + JSON error while no model is running
  * permissive CORS so browser apps can call it directly

The vLLM backend binds 127.0.0.1:8001 (internal only) with the same verified
flags as the previous vllm_direct_start.sh launcher: TP=2 across both RTX
2080 Ti (NVLink), FP8 (e4m3), MTP3 speculative decoding, PIECEWISE CUDA
graphs, 98304 context, 0.94 GPU memory utilization.

## Models (registry: models.json)

| id | model dir | served name | sync mode |
|---|---|---|---|
| official (default) | /home/tianyixia/models/Qwen3.8-27B-FP8 | qwen38-27b-fp8-fast-mtp3 | auto |
| uncensored | /home/tianyixia/models/qwen-3.8-27b-uncensored | Qwen3.8-27B-FP8-uncensored | safe |

Both are ~29 GiB FP8 checkpoints of the same architecture; only one can fit
in VRAM at a time (2x 22 GiB GPUs, ~21.7 GiB used per GPU when serving).

## Management API (port 8500)

| endpoint | description |
|---|---|
| GET /api/status | backend phase/health/pid, per-model state, GPU VRAM, host RAM |
| GET /api/models | model registry |
| GET /api/logs?lines=N&model=ID | backend log tail |
| POST /api/start {"model":"uncensored"} | start a model (202; ready when /health turns 200) |
| POST /api/stop | stop the running model (idempotent) |
| POST /api/switch {"model":"official"} | stop + start (one operation) |
| GET /health | manager liveness |

curl examples:

    curl http://192.168.3.200:8500/api/status
    curl -X POST http://192.168.3.200:8500/api/switch \
      -H 'Content-Type: application/json' -d '{"model":"uncensored"}'
    curl http://192.168.3.200:8000/v1/models
    curl http://192.168.3.200:8000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen38-27b-fp8-fast-mtp3","messages":[{"role":"user","content":"hi"}],"max_tokens":128}'

Switching takes ~1.5-3 min (CUDA graph capture on model load). The first
request after a fresh load may JIT-compile a few Triton kernels (latency
spike; normal for this fork).

## Deployment / operations

* systemd unit: vllm-manager (restarts automatically, starts at boot)
* state: /var/lib/vllm-manager/state.json (survives reboots; the default
  model auto-starts at boot unless it was explicitly stopped)
* backend logs: /var/lib/vllm-manager/logs/<model>-<ts>.log
* when the manager restarts it **adopts** a still-running backend instead of
  starting a second one
* the legacy launcher scripts (vllm-qwen/run-vllm-qwen.sh) still work, but
  they bind port 8000 themselves - stop the manager first
  (sudo systemctl stop vllm-manager) if you want to use them
* no authentication: the host firewall already opens all LAN ports; add a
  reverse proxy with auth in front of port 8500 if this must be exposed
  beyond the trusted LAN
