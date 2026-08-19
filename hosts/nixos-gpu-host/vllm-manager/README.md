# vLLM model manager (nixos-gpu-host)

One stdlib-only Python service that turns the GPU host into a remote model
control box, fronted by nginx TLS:

* **Control panel (web UI + management API)** — https://192.168.3.200:8000/
  * choose which model runs (start / stop / switch)
  * live VRAM report per GPU (via nvidia-smi) and host RAM
  * backend health, uptime, per-model log tails
* **OpenAI-compatible API** — https://192.168.3.200:8001/v1
  * every request is streamed through to the vLLM backend
    (chat/completions, completions, models, /docs, ...)
  * 503 + JSON error while no model is running
  * permissive CORS so browser apps can call it directly

Port map (public -> internal):

| role | public (TLS via nginx) | internal (127.0.0.1, plain HTTP, not exposed) |
|---|---|---|
| management UI + API | :8000 | :8501 (manager control) |
| OpenAI model API | :8001 | :8502 (manager proxy) -> :9001 (vLLM backend) |

No plain-HTTP listener is exposed on the LAN: the public nginx servers are
TLS-only with ssl_reject_handshake, and the manager/backend bind loopback.

## TLS certificate

The certificate is a self-signed leaf generated at build time (valid 10
years) with SANs: DNS:nixos-gpu-host, DNS:localhost, IP:192.168.3.200,
IP:127.0.0.1. Download and install it as trusted once:

    curl -k https://192.168.3.200:8000/ca.crt -o vllm-manager-ca.crt
    # then import vllm-manager-ca.crt into your OS/browser trust store

Until then, curl needs -k and browsers will show a certificate warning.

## Models (registry: models.json)

| id | model dir | served name | sync mode |
|---|---|---|---|
| official (default) | /home/tianyixia/models/Qwen3.8-27B-FP8 | qwen38-27b-fp8-fast-mtp3 | auto |
| uncensored | /home/tianyixia/models/qwen-3.8-27b-uncensored | Qwen3.8-27B-FP8-uncensored | safe |

Both are ~29 GiB FP8 checkpoints of the same architecture; only one can fit
in VRAM at a time (2x 22 GiB GPUs, ~21.7 GiB used per GPU when serving).

## Management API (https port 8000)

| endpoint | description |
|---|---|
| GET /api/status | backend phase/health/pid, per-model state, GPU VRAM, host RAM |
| GET /api/models | model registry |
| GET /api/logs?lines=N&model=ID | backend log tail |
| POST /api/start {"model":"uncensored"} | start a model (202; ready when /health turns 200) |
| POST /api/stop | stop the running model (idempotent) |
| POST /api/switch {"model":"official"} | stop + start (one operation) |
| GET /health | manager liveness |
| GET /ca.crt | public certificate (install to trust) |

curl examples:

    curl -k https://192.168.3.200:8000/api/status
    curl -k -X POST https://192.168.3.200:8000/api/switch       -H 'Content-Type: application/json' -d '{"model":"uncensored"}'
    curl -k https://192.168.3.200:8001/v1/models
    curl -k https://192.168.3.200:8001/v1/chat/completions       -H 'Content-Type: application/json'       -d '{"model":"qwen38-27b-fp8-fast-mtp3","messages":[{"role":"user","content":"hi"}],"max_tokens":128}'

Switching takes ~1.5-3 min (CUDA graph capture on model load). The first
request after a fresh load may JIT-compile a few Triton kernels (latency
spike; normal for this fork).

## Deployment / operations

* systemd units: vllm-manager (control/API, restarts automatically, starts at
  boot) and nginx (TLS termination, starts after the manager)
* state: /var/lib/vllm-manager/state.json (survives reboots; the default
  model auto-starts at boot unless it was explicitly stopped)
* backend logs: /var/lib/vllm-manager/logs/<model>-<ts>.log
* when the manager restarts it **adopts** a still-running backend instead of
  starting a second one (KillMode=process keeps the backend out of the
  manager's kill scope)
* the legacy launcher scripts (vllm-qwen/run-vllm-qwen.sh) still work, but
  they bind port 8000 themselves - stop the manager and nginx first
  (sudo systemctl stop vllm-manager nginx) if you want to use them
* no authentication: TLS here is encryption + MITM protection for the LAN,
  not authorization; add basic-auth or a client cert in nginx if the host is
  ever exposed beyond the trusted LAN
