# DeepSeek-V4-Flash-0731 distributed inference — performance report

Date: 2026-08-16
Repo: `nixos-config` (branch `main`)
Hardware:
- `nixos-gpu-host` (bare metal, 192.168.3.200 / 10.0.0.200, MTU 9000):
  2x RTX 2080 Ti 22GB (Turing sm_75), AMD EPYC 7F72 24C/48T, 125GB RAM, NVMe.
  Both GPUs expose NVLink 2.2 hardware, but the driver currently reports all
  NVLink links inactive: `nvidia-smi topo -m` shows GPU0<->GPU1 = NODE,
  `nvidia-smi nvlink --status` says "all links are inActive", and
  `nvidia-smi topo -p2p r` shows "CNS" (chipset not supported). The bridge is
  physically installed, so treat this as a seating/bridge/driver issue to
  verify; all benchmarks here were measured with the link reported inactive.
- `nixos-gpu-vm` (Proxmox VM, 192.168.3.103 / 10.0.0.103, MTU 9000):
  Tesla P40 via NVIDIA vGPU (mdev `nvidia-53`, GRID P40-24Q, driver 535.309.01),
  16GB RAM. It cannot load the full 155GB model locally; its job is to expose the
  P40 over llama.cpp RPC.

## Model

- Files: `/home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-0000{1,2}-of-00002.gguf`
  on `nixos-gpu-host`. Part 2 size verified: header + tensor-offset walk matches
  the file size exactly (154,986,288,576 bytes), so the SCP transfer is complete.
- GGUF metadata:
  - architecture `deepseek4`, `general.size_label = 256x8.4B`
  - 43 layers, context 1,048,576, hidden 4096
  - 256 experts, 6 routed, 1 shared
  - `general.file_type = 38` (MXFP4 MoE); tensors are GGML_TYPE_MXFP4 (MoE
    weights) + Q8_0 (attention/dense weights) + F32 scales
  - total tensor bytes 154,986,200,988; `llama-bench` reports 144.34 GiB,
    284.33 B total params
  - per-layer weights: ~3.57GB (non-indexer layers) / ~3.59GB (indexer layers)
- DSpark draft model: **not bundled / not present**. The GGUF contains only the
  main model; there are no `dflash.*` metadata keys and no separate draft GGUF
  anywhere on `nixos-gpu-host`. `draft-dspark` is compiled in, but needs a
  separate dflash draft model (`--model-draft`). Speculative decoding was
  therefore not benchmarked.

## llama.cpp version decision

- `nixpkgs-stable` 26.05 packages llama.cpp `b9190`. Checked source: it has no
  `deepseek4`/`dflash`/`dsv4` model support and no `draft-dspark` speculative
  type. It cannot load this GGUF.
- Pinned `b10331` on both hosts. This is the revision already used by the old
  MXFP4 cluster; `deepseek4` and DSpark speculative decoding are upstream there.
- The five RPC/DSV4 patches from `packages/patches/` were re-applied to pristine
  b10331. They are still required for RPC graph caching, server-side MXFP4
  repack, compressed-KV placement, draft path fix and RPC tensor debug.
- `b10442` (latest tag checked) still has `deepseek4` in
  `llm_arch_supports_sm_tensor`'s *unsupported* list, so upgrading would not
  give us `-sm tensor` for this architecture.

## TP vs PP

User default was TP=2 on the 2080 Tis. Measured result: **TP is unavailable**.

- `-sm tensor` exits during model load with:
  `LLAMA_SPLIT_MODE_TENSOR not implemented for architecture 'deepseek4'`.
  This is also true on latest `b10442`.
- `-sm row` was tried locally (`-ngl 12 -ts 1,1`) and also failed to load.
- Therefore the cluster uses **pipeline parallelism (`-sm layer`) across
  RPC P40 + 2x local 2080 Ti**, with `-ngl 7` as the maximum stable GPU-layer
  count found.

## CUDA stability workaround (important)

With b10331 + CUDA 12.9 on Turing sm_75:
- Synthetic `llama-bench` works with `-sm layer` up to `-ngl 7`.
- `-ngl 8` and above crash on the first decoded token with
  `CUDA error: an illegal memory access was encountered` on local CUDA0.
- Real prompts crash even at `-ngl 7` unless both of the following are set:
  `GGML_CUDA_DISABLE_FUSION=1` and `GGML_CUDA_DISABLE_GRAPHS=1`.
  `GGML_CUDA_DISABLE_FUSION=1` alone is not enough for real prompts.
- The `llama-server` unit on `nixos-gpu-host` ships with both env vars.

## Tuning iterations

All cluster runs use `--rpc 10.0.0.103:50052`. `llama-bench` model load is
~2.5-3.0 min per run on the NVMe host.

| Config | pp128 t/s | tg64 t/s | Result |
|---|---:|---:|---|
| `-ngl 7 -sm layer -ts 1,1,1 -b 256 -ub 128` (fusion/graphs on) | 17.28 | 2.91 | synthetic OK; real prompts crash |
| `-ngl 7 -sm layer -ts 1,1,1 -b 256 -ub 128` (fusion+graphs OFF) | 16.14 | 2.84 | **recommended stable** |
| `-ngl 7 -sm layer -ts 2,1,1 -b 256 -ub 128` | 2.18 | 1.67 | P40 got 4 layers -> much worse |
| `-ngl 7 -sm layer -ts 1,1,1 -b 512 -ub 256` | 4.61 | 0.97 | too-large ubatch hurts |
| `-ngl 8 -sm layer -ts 1,1,1` | - | - | CUDA illegal memory access |
| `-ngl 12 -sm tensor -ts 3,3,1` | - | - | not implemented for deepseek4 |
| `-ngl 12 -sm row -ts 1,1` (local only) | - | - | failed to load |

## Baseline numbers

### Cluster (best stable)

Command on `nixos-gpu-host`:

```sh
env GGML_CUDA_DISABLE_FUSION=1 GGML_CUDA_DISABLE_GRAPHS=1 \
  /run/current-system/sw/bin/llama-bench \
  -m /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --rpc 10.0.0.103:50052 \
  -p 128 -n 64 -b 256 -ub 128 -r 2 \
  -ngl 7 -sm layer -ts 1,1,1 -o md
```

Final warm result:
- prefill: **16.14 t/s** at 128 tokens
- decode: **2.84 t/s** at 64 tokens

### gpu-host alone (2x 2080 Ti, no RPC)

```sh
env GGML_CUDA_DISABLE_FUSION=1 GGML_CUDA_DISABLE_GRAPHS=1 \
  llama-bench -m /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  -p 128 -n 64 -b 128 -ub 64 -r 2 -ngl 6 -sm layer -ts 1,1 -o md
```

- prefill: **9.48 t/s**, decode: **2.35 t/s**
- `-ngl 7` local-only failed to create context (GPU memory/context allocation),
  so local-only max stable is `-ngl 6`.

### gpu-vm alone (P40 sanity, tiny model)

```sh
llama-cpp-llama-bench -m /tmp/qwen2.5-0.5b-q4.gguf -p 64 -n 32 -b 128 -ub 64 \
  -r 2 -ngl 99 -sm layer -o md
```

- prefill: **3854.80 t/s**, decode: **177.54 t/s** (CUDA backend healthy).

### CPU-only (gpu-host, no GPU offload)

`llama-cli -ngl 0` with a real 44-token prompt, `-n 16 -b 64 -ub 64`:
`[ Prompt: 0.6 t/s | Generation: 0.5 t/s ]`.

## Per-stage timing breakdown

Representative workload: 128 prompt tokens + 64 generated tokens.

| Stage | Where | Time | Notes |
|---|---:|---:|---|
| Model load + tensor placement | gpu-host NVMe + 40G RPC | ~170 s | 144.34 GiB GGUF mmap; 10.73GB of tensors sent to P40 over RPC |
| RPC tensor transfer at load | 40G link | ~4 s | layers 37-39 (~10.73GB) at ~25 Gb/s practical ceiling |
| Prefill (prompt processing) | 36 CPU layers + 7 GPU layers (3 RPC + 2 + 2) | 128 / 16.14 = **7.9 s** | CPU MoE layers dominate |
| Decode (generation) | same split | 64 / 2.84 = **22.5 s** | CPU layers still dominate |
| RPC activation transfer during decode | 40G link | <0.1 s | ~2 remote transfers per token (hidden state 4096, f32 = 16KB each) |
| KV cache / compressed KV | CPU RAM | <0.5 s | context is only 192 tokens in llama-bench; compressed DSV4 KV kept client-side by patch |
| Sampling | CPU | <0.1 s | negligible for 64 tokens |

**Bottleneck: CPU/RAM layers.** Only 7 of 43 layers fit in stable GPU offload;
the other 36 layers run on CPU. RPC/40G is *not* the bottleneck. Evidence:
- CPU-only decode is ~0.5 t/s; moving just 7 layers to GPU raises decode to
  ~2.8 t/s.
- Giving the P40 more layers (`-ts 2,1,1`) drops decode to ~1.7 t/s because the
  P40 becomes the slower pipeline stage.
- RPC link delta for a full load+benchmark is dominated by one-time weight
  transfer; per-token activation traffic is ~32KB.

## Current systemd setup

- `nixos-gpu-vm`: `llama-rpc-server.service` (enabled, running)
  `ExecStart=llama-cpp-ggml-rpc-server -H 10.0.0.103 -p 50052 -d CUDA0`
- `nixos-gpu-host`: `llama-server.service` (unit exists, **not enabled/auto-start**)
  starts the OpenAI-compatible server with the best measured flags and the two
  CUDA workaround env vars.
- `nvidia-gridd.service` PIDFile fixed to `/run/nvidia-gridd/nvidia-gridd.pid`;
  service is stable and licensed.

## Handoff commands

### Start the cluster

```sh
# on nixos-gpu-vm (already enabled at boot; use these to check/restart)
sudo-env -c 'systemctl status llama-rpc-server'
sudo-env -c 'systemctl restart llama-rpc-server'

# on nixos-gpu-host: start the serving process
sudo-env -c 'systemctl start llama-server'
sudo-env -c 'journalctl -u llama-server -f'
```

### Reproduce the benchmark

On `nixos-gpu-host`:

```sh
env GGML_CUDA_DISABLE_FUSION=1 GGML_CUDA_DISABLE_GRAPHS=1 \
  /run/current-system/sw/bin/llama-bench \
  -m /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --rpc 10.0.0.103:50052 \
  -p 128 -n 64 -b 256 -ub 128 -r 2 \
  -ngl 7 -sm layer -ts 1,1,1 -o md
```

Expected duration: ~3 min load + ~1.5 min benchmark = **~5 min per run**.

### Next tuning targets

1. Fix the `-ngl 8+` CUDA illegal memory access in b10331 / current master for
   deepseek4 on sm_75; then re-tune `-ngl` upward. Every extra GPU layer removes
   ~3.57GB of CPU work and should improve decode roughly linearly until the P40
   or a 2080 Ti becomes the bottleneck.
2. Try a CUDA 12.2 build for `nixos-gpu-host` (same toolchain as the stable
   gpu-vm build) to see if it fixes the `-ngl 8+` crash without the
   fusion/graphs workaround.
3. Obtain a DSpark dflash draft GGUF and benchmark `--spec-type draft-dspark`
   with `--model-draft`; the patch for the draft path is already applied.
4. Re-test `-sm tensor` against a future llama.cpp release that implements it
   for `deepseek4`.
