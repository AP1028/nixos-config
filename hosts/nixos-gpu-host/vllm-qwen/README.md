# vLLM Qwen3.8-27B-FP8 on gpu-host (2x RTX 2080 Ti 22GB)

Serves **Qwen/Qwen3.8-27B-FP8** on `nixos-gpu-host` with the
[weicj/vLLM-2080Ti-Definitive](https://github.com/weicj/vLLM-2080Ti-Definitive)
fork (branch `vllm-2080ti-deifinitive`, fork release v0.1.15), TP=2, NVLink,
CUDA 12.9 host toolkit + torch 2.11.0+cu128, driver 595.71.05.

- Model dir: `/home/tianyixia/models/Qwen3.8-27B-FP8` (full FP8 repo, 81 files,
  28.77 GiB, including `mtp.safetensors` and `outside.safetensors`)
- Runtime tree: `~/vLLM-2080Ti-Definitive` (built with `./build.sh` in `.venv`)
- Previous llama.cpp DeepSeek work stays parked: `llama-server` is stopped and
  `/home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-*.gguf` is untouched.

## Handoff commands

**Daily use goes through the vllm-manager systemd service instead** (see
`../vllm-manager/README.md`): control panel `https://192.168.3.200:8000/`,
OpenAI API `https://192.168.3.200:8001/v1` (self-signed TLS, install the
CA from `https://192.168.3.200:8000/ca.crt`). The manager owns ports
8000/8001 and runs the official and uncensored FP8 checkpoints interchangeably.

The scripts below still work but bind port 8000 themselves; stop the manager
first if you need them (`sudo systemctl stop vllm-manager`).

```sh
# on nixos-gpu-host, as tianyixia
cd ~/nixos-config/hosts/nixos-gpu-host/vllm-qwen

./run-vllm-qwen.sh fast      # recommended daily: MTP3 + PIECEWISE CUDAGraph
./run-vllm-qwen.sh balanced  # MTP4: higher synthetic/filler decode
./run-vllm-qwen.sh peak      # MTP12 synthetic peak, benchmark-only
./stop-vllm-qwen.sh
```

Each start prints the vLLM PID/log path and exits when the health check passes.
The OpenAI-compatible endpoint is `http://192.168.3.200:8000/v1` and
`http://127.0.0.1:8000/v1` on the host.

Smoke / benchmark:

```sh
python3 bench_single_stream.py --url http://127.0.0.1:8000 \
  --model qwen38-27b-fp8-fast-mtp3 --runs 3 --max-tokens 128
```

## Final measured numbers (2026-08-16, Qwen3.8-27B-FP8, TP=2)

Single request, 117 prompt tokens, 128 generated tokens, one warmup request
excluded. "prose" = the fixed English paragraph in `bench_single_stream.py`;
"filler" = fork's `tools/profile_request.py --pure-filler` (PP128/TG128).

| Preset / config | prefill tok/s | prose decode tok/s | filler decode tok/s | VRAM per GPU |
|---|---:|---:|---:|---:|
| `fast` MTP3 PIECEWISE, sync=auto (recommended) | ~1093 | **64.0** | 95.5 | 21.7 GiB |
| `balanced` MTP4 PIECEWISE, sync=auto | ~1063 | 63.3 | **109.4** | 20.8 GiB |
| `peak` MTP12 PIECEWISE, sync=auto | ~881 | 46.5 | **177.7** | 22.0 GiB |
| shipped normal fp16kv-128K (98K fit) | 1101 | 61.9 | — | 21.7 GiB |
| shipped fast full-graph MTP3 | 1097 | 44.7 | — | 20.3 GiB |
| MTP0 (no MTP), full graph | 1212 | 33.1 | — | 20.0 GiB |
| MTP3 eager (no CUDAGraph) | 1050 | 30.7 | — | 21.7 GiB |
| MTP3 + int8 KV | 1079 | 58.1 | — | 20.3 GiB |
| MTP3 + turboquant_k8v4 KV | 1093 | 59.3 | — | 19.8 GiB |
| MTP3, custom allreduce disabled | 1066 | 57.9 | — | 21.7 GiB |

Host RAM used at idle after load: ~10 GiB. Full tuning history and commands:
[`../../../docs/qwen3.8-27b-vllm-2080ti-report.md`](../../../docs/qwen3.8-27b-vllm-2080ti-report.md).

Interpretation: PIECEWISE CUDA graphs + MTP are the two big levers (both
roughly double decode). `VLLM_SM75_SPEC_SYNC_MODE=auto` is measurably faster
than the launcher's mode-default `safe` (+4 tok/s prose). FP16 KV beats
INT8/TurboQuant for short single-stream decode. MTP3 is the best natural-text
preset; MTP4 trades ~1.5 tok/s of prose for +14 filler tok/s; high-K MTP only
wins on highly compressible filler, so `peak` is a benchmark preset.

## NixOS build / toolchain notes

This directory is imported by `hosts/nixos-gpu-host/default.nix` as a NixOS
module. The module:

- installs `uv`, `gcc14`, `cmake`, `ninja`;
- builds a Debian/Ubuntu-style CUDA compatibility tree exposed at
  `/etc/vllm-cuda-home` (`targets/x86_64-linux/lib`, `lib64`, ...) from
  `pkgs.cudaPackages.cudatoolkit`; and
- installs a `/sbin/ldconfig` shim because Triton hard-codes that path on
  Linux (NixOS ships ldconfig only under `/run/current-system/sw/bin`).

Fork build (already done on the host; repeat only after NixOS rebuild pulls
the module):

```sh
cd ~/vLLM-2080Ti-Definitive
CUDA_HOME=/etc/vllm-cuda-home \
CC=$(command -v gcc) CXX=$(command -v g++) CUDAHOSTCXX=$(command -v g++) \
NVCC_PREPEND_FLAGS="-I/etc/vllm-cuda-home/include" \
LD_LIBRARY_PATH=/run/opengl-driver/lib:/etc/vllm-cuda-home/lib \
ASSUME_YES=1 MAX_JOBS=16 BUILD_MAX_JOBS=16 BUILD_AUTO_MAX_JOBS_CAP=16 \
BUILD_TORCH_PRIMARY_TIMEOUT_SECONDS=3600 \
BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS=1800 \
BUILD_GIT_PRIMARY_TIMEOUT_SECONDS=900 \
./build.sh
```

Known NixOS build gotchas:

- the PyTorch wheel index is slow for the 658 MB cudnn wheel; if the build
  script's torch step stalls, pre-install the exact wheels (see commit history
  of this README for the command list), then rerun `build.sh`;
- GCC 15 is too new for CUDA 12.9 `nvcc`; the module's `gcc14` is required;
- `/sbin/ldconfig` and the CUDA layout shim above are required at runtime too.

## Profile changes

`profiles/*.env` here are route profiles consumed via
`PROFILE_FILE=... ./launcher.sh --non-interactive`. They intentionally force
`COMPILATION_CONFIG_JSON` to PIECEWISE because `MODE=fast`'s
FULL_AND_PIECEWISE default is slower on this Turing/hybrid-attention model,
and `run-vllm-qwen.sh` pins `VLLM_ALLOW_MAMBA_SPEC_FULL_CUDAGRAPH=0` plus
`VLLM_SM75_SPEC_SYNC_MODE=auto` for the same reason.
