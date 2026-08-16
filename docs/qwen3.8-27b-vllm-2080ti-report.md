# Qwen3.8-27B-FP8 on vLLM-2080Ti-Definitive — gpu-host report

Date: 2026-08-16
Host: `nixos-gpu-host` (192.168.3.200 / 10.0.0.200)
Operator: tianyixia

## 1. Summary

The gpu-host is now running the
[weicj/vLLM-2080Ti-Definitive](https://github.com/weicj/vLLM-2080Ti-Definitive)
fork (branch `vllm-2080ti-deifinitive`, fork release v0.1.15) with
`Qwen/Qwen3.8-27B-FP8`, TP=2 across the two 22GB RTX 2080 Ti cards, NVLink
active, MTP and PIECEWISE CUDA graphs enabled.

Measured single-request decode (117 prompt tokens / 128 generated tokens,
warmup excluded, median of 3-5):

| Configuration | Real English prose decode | Fork pure-filler PP128/TG128 decode |
|---|---:|---:|
| **`fast` preset, MTP3, PIECEWISE, sync=auto (recommended)** | **64.0 tok/s** | 95.5 tok/s |
| `balanced` preset, MTP4, PIECEWISE, sync=auto | 63.3 tok/s | 109.4 tok/s |
| **`peak` preset, MTP12, PIECEWISE, sync=auto** | 46.5 tok/s | **177.7 tok/s** |

The highest single-stream decode reached is **177.7 tok/s** (pure-filler
synthetic PP128/TG128). On natural text, MTP3 is the best stable preset;
MTP4 is the synthetic/real compromise; high-K MTP only wins on highly
compressible filler. The final deployed launcher server measured 64.0 tok/s
prose / 95.5 tok/s filler (the direct-run matrix once hit 64.8).

Bottleneck: Turing FP8 is weight-only Marlin (sm_75 has no native FP8 matmul),
and decode is bounded by GPU memory bandwidth / MTP acceptance. MTP3/4 yields a
~2x decode gain over no-MTP; PIECEWISE CUDA graphs add another ~2x. NVLink +
custom allreduce is not the limiter at single-stream (disabling custom
allreduce drops decode to 57.9 tok/s).

## 2. Repo study

- README validates Qwen3.x 27B FP8 on 2x 2080 Ti 22GB TP=2 with CUDA 12.8 +
  torch 2.11.0+cu128.
- `build.sh` creates `.venv`, installs exact torch wheels, fetches
  FlashQLA-SM70-SM75 / CUTLASS v4.4.2 / Triton v3.6.0, builds CUDA extensions,
  and validates runtime components.
- `launcher.sh` applies `.env` route profiles and translates them into:
  `--quantization fp8 --dtype half --tensor-parallel-size 2 --enable-chunked-prefill
  --max-num-seqs 1 --speculative-config '{"method":"mtp",...}'` plus a
  `--compilation-config` CUDAGraph block.
- Exact validated profile for Qwen 27B FP8: `qwen27b/normal/fp8/fp16kv-128K-mtp3-text-only.env`
  and `qwen27b/fast/fp8/*`. On this host both shipped contexts were slightly too
  large for the KV cache at their shipped `GPU_UTIL`, so the checked-in profiles
  use `MAX_MODEL_LEN=98304` + `GPU_UTIL=0.94`, which loads with headroom.

## 3. Model download / verification

- Directory: `/home/tianyixia/models/Qwen3.8-27B-FP8`
- 81/81 HF repo files present; all sizes match the HF API tree
  (30,890,036,483 bytes remote). Includes `mtp.safetensors` (477,202,224 B)
  and `outside.safetensors` (6,007,102,112 B). No BF16 repo was used.
  `huggingface-cli download` was spot-checked for `config.json` /
  `generation_config.json` (byte-identical to the local copy); a full
  re-download was not run because the files are already complete on NVMe.

## 4. NixOS build route

The host already had CUDA 12.9 via `cudaPackages.cudatoolkit`. Per the NixOS
workflow, `hosts/nixos-gpu-host/vllm-qwen/default.nix` was added to the flake,
committed, pushed, pulled on the host, and applied with
`sudo-env -c 'nixos-rebuild switch ...'`. The module provides:

- `uv`, `gcc14`, `cmake`, `ninja` in `environment.systemPackages` (GCC 15 is
  too new for nvcc 12.9);
- `/etc/vllm-cuda-home`: a Debian/Ubuntu-style CUDA layout built from the Nix
  cudatoolkit (`targets/x86_64-linux/lib` etc.); and
- `/sbin/ldconfig` shim, because Triton hard-codes that path and NixOS has no
  ld.so cache there.

Fork build on the host:

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

Build result: `BUILD OK` in 12m30s after the toolchain was in place.
Build log: `~/vLLM-2080Ti-Definitive/build-logs/build-20260816-182226.log`.

Two NixOS-specific build issues were fixed:

1. `build.sh` default torch install timeout (90s) is too short for the 820MB
   torch wheel on this uplink. Pre-installing the exact torch/cuda wheels from
   the fast TUNA mirror and rerunning solved it (details in the vllm-qwen
   README).
2. FlashQLA's torch extension initially failed to detect CUDA until
   `LD_LIBRARY_PATH` included the CUDA and driver libs.
3. Runtime initially failed with `FileNotFoundError: /sbin/ldconfig`; fixed in
   NixOS config with the shim (and `TRITON_LIBCUDA_PATH=/run/opengl-driver/lib`
   is exported by the launcher wrapper).

## 5. Smoke test (first successful profile)

Command (launcher, normal fp16kv profile with the host-fit context override):

```sh
cd ~/vLLM-2080Ti-Definitive
CUDA_HOME=/etc/vllm-cuda-home LD_LIBRARY_PATH=/run/opengl-driver/lib \
TRITON_LIBCUDA_PATH=/run/opengl-driver/lib \
MODEL_DIR=/home/tianyixia/models/Qwen3.8-27B-FP8 \
PROFILE=qwen27b/normal/fp8/fp16kv-128K-mtp3-text-only.env \
MODE=normal GPU_DEVICES=0,1 TP_SIZE=2 MAX_MODEL_LEN=98304 GPU_UTIL=0.94 \
VLLM_COMPILE_PREWARM=0 PORT=8000 SERVICE_SCOPE=lan \
./launcher.sh --non-interactive
```

Smoke result (3 timed requests, 117 prompt / 128 generated tokens):

- prefill: 1100.8 tok/s
- decode: 61.9 tok/s
- VRAM: 21,726 MiB used per GPU (22,528 MiB total)
- host RAM: 9.4 GiB used after load
- startup: ~2.5 min warm with cold torch.compile; subsequent starts ~75s

The shipped 128K context did not fit on this host's memory partition
(4.64 GiB KV needed vs 3.74 GiB available at util 0.92), so `MAX_MODEL_LEN`
was lowered to 98304 for all local presets; short-decode numbers are
unaffected.

## 6. Tuning iterations

All runs below use TP=2, FP16/default KV unless noted, one warmup request
excluded, 117-prompt / 128-generated English prose from
`bench_single_stream.py`. Each row is a fresh server start and the median of 3
timed requests. Direct `vllm.entrypoints.openai.api_server` was used for the
matrix (same flags the launcher builds); the final presets were re-run through
the launcher.

| Tag | Graph | MTP | Other | prefill tok/s | decode tok/s |
|---|---:|---:|---|---:|---:|
| normal-mtp3-pw (launcher) | PIECEWISE | 3 | launcher normal (`sync=safe`) | 1101 | 61.9 |
| fast-mtp3-full | FULL_AND_PIECEWISE | 3 | launcher-fast equivalent | 1070 | 47.5 |
| normal-mtp3-pw (direct) | PIECEWISE | 3 | `sync=auto` (fork default) | 1099 | 64.7 |
| mtp3-pw-auto | PIECEWISE | 3 | explicit `sync=auto` | 1092 | **64.8** |
| mtp4-pw-auto | PIECEWISE | 4 | explicit `sync=auto` | 1063 | 63.3 |
| normal-mtp3-pw-nosync | PIECEWISE | 3 | `sync=nosync` | 1090 | 63.4 |
| mtp3-pw-mamba-full | PIECEWISE | 3 | mamba full graph 1 | 1090 | 60.3 |
| mtp3-full-nomamba-full | FULL_AND_PIECEWISE | 3 | mamba full 0 | 1090 | 60.5 |
| mtp3-eager | none (eager) | 3 | no CUDA graphs | 1050 | 30.7 |
| nomtp-full | FULL_AND_PIECEWISE | 0 | no MTP | 1212 | 33.1 |
| mtp2-pw | PIECEWISE | 2 | sync=safe | 1118 | 57.0 |
| mtp4-pw | PIECEWISE | 4 | sync=safe | 1071 | 64.3 |
| mtp5-pw | PIECEWISE | 5 | sync=safe | 1036 | 61.5 |
| mtp6-pw-realtext | PIECEWISE | 6 | sync=safe | 1014 | 59.4 |
| mtp8-pw-realtext | PIECEWISE | 8 | sync=safe | 961 | 53.5 |
| mtp8-pw-auto | PIECEWISE | 8 | sync=auto | 965 | 54.0 |
| mtp12-pw-auto-realtext | PIECEWISE | 12 | sync=auto, util 0.95 | 881 | 46.5 |
| mtp3-pw-int8kv | PIECEWISE | 3 | `--kv-cache-dtype int8_per_token_head` | 1079 | 58.1 |
| mtp3-pw-tqk8v4 | PIECEWISE | 3 | `turboquant_k8v4`, batch 2560 | 1093 | 59.3 |
| mtp3-pw-nocustomar | PIECEWISE | 3 | `--disable-custom-all-reduce` | 1066 | 57.9 |
| mtp3-pw-noprefix | PIECEWISE | 3 | prefix cache off | 1106 | 62.7 |
| mtp3-pw-batch4096 | PIECEWISE | 3 | max batched tokens 4096 | 1102 | 61.7 |

Conclusions:

- PIECEWISE beats FULL_AND_PIECEWISE on this hybrid-linear-attention model.
- `VLLM_SM75_SPEC_SYNC_MODE=auto` (the fork default) is faster than the
  launcher's mode-default `safe`; `nosync` is also slower here.
- `VLLM_ALLOW_MAMBA_SPEC_FULL_CUDAGRAPH=1` loses; keep 0.
- MTP is worth ~2x (33.1 → 64.8). MTP3 is the best stable natural-text
  setting; MTP4 trades about 1.5 prose tok/s for +14 filler tok/s. One early
  MTP4 window hit 67.2 tok/s but did not reproduce on re-runs.
- CUDA graphs are worth ~2x (30.7 eager → 67.2 piecewise).
- FP16 KV beats INT8 and TurboQuant for short single-stream decode.
- Custom NVLink allreduce helps (57.9 → 64.7).
- `MAX_BATCHED_TOKENS=2048` beats 4096 for single-stream.

### 6.1 Synthetic (pure-filler) MTP sweep

Using the fork's own `tools/profile_request.py --pure-filler`, PP128/TG128,
two measured runs after one warmup, PIECEWISE graphs:

| MTP_K | sync=safe decode tok/s | sync=auto decode tok/s |
|---:|---:|---:|
| 3 | 91.0 | 95.7 |
| 4 | 104.5 | 109.4 |
| 5 | 115.4 | — |
| 6 | 126.9 | — |
| 7 | 141.0 | — |
| 8 | 141.1 | 146.0 |
| 9 | — | 159.8 |
| 10 | — | 163.4 |
| 11 | — | 170.1 |
| 12 | — | **177.7** |

MTP13 did not start cleanly at `MAX_MODEL_LEN=98304` / util 0.95 and was not
pursued further; MTP10 required util 0.95 at this context length.

## 7. Final shipped presets and handoff

All files live under `~/nixos-config/hosts/nixos-gpu-host/vllm-qwen/`
(tracked in the nixos-config repo). Profiles force PIECEWISE
`COMPILATION_CONFIG_JSON`; `run-vllm-qwen.sh` pins
`VLLM_ALLOW_MAMBA_SPEC_FULL_CUDAGRAPH=0` and
`VLLM_SM75_SPEC_SYNC_MODE=auto`.

```sh
# on nixos-gpu-host, as tianyixia
cd ~/nixos-config/hosts/nixos-gpu-host/vllm-qwen

./run-vllm-qwen.sh fast      # recommended daily: MTP3, 64.0 real / 95.5 filler tok/s
./run-vllm-qwen.sh balanced  # MTP4: 63.3 real / 109.4 filler tok/s
./run-vllm-qwen.sh peak      # MTP12: 46.5 real / 177.7 filler tok/s (benchmark preset)
./stop-vllm-qwen.sh
```

Endpoint: `http://192.168.3.200:8000/v1` (OpenAI-compatible), LAN scope.
Runtime logs: `~/vLLM-2080Ti-Definitive/run-logs/`.
The llama.cpp DeepSeek unit remains stopped; DeepSeek GGUFs are untouched.

## 8. Bottleneck and possible next steps

- The 2080 Ti has no native FP8 tensor cores; the fork logs that FP8 runs as
  weight-only Marlin. Decode is memory-bandwidth-bound (~1.2 TB/s combined
  HBM) plus MTP acceptance.
- Natural-text decode tops out around 64-65 tok/s with MTP3; filler peaks at
  177.7 tok/s with MTP12 because almost every draft token is accepted.
- Further real-workload gains would come from better acceptance-aware MTP
  (e.g. 2-tier draft selection), TurboQuant kernels for the hybrid linear
  attention path, or a shorter-context tuned graph; on this silicon there is
  no FP8-matmul headroom left.
