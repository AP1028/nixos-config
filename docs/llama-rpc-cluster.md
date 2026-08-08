# llama.cpp RPC cluster (DeepSeek V4 Flash, MXFP4)

## Topology

| Host | IP | Role | Memory used by model |
|---|---|---|---|
| `nixos-gpu-vm` | 192.168.3.103 | **client** (llama-server, holds model files) + worker | P40 6 layers, GTX 1060 1 layer, RAM 15 layers |
| `asusg16` | 192.168.3.250 | worker | RTX 5080 4 layers, RAM 12 layers |
| `nixos-intel-7700k` | 192.168.3.200 | worker (CPU only) | RAM 5 layers |

Model: `/home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-0000{1,2}-of-00002.gguf`
(144.34 GiB, 43 layers x ~3.33 GiB, split across 2 gguf parts).

## Fill order (weight placement)

`--device RPC3,RPC0,RPC1,RPC2,RPC4,RPC7 --tensor-split 4,6,1,15,12,6`

Device order is the memory fill order (GPUs first, then RAMs in
gpu-vm -> asusg16 -> 7700k order). RPC indices with
`--rpc 192.168.3.103:50052,192.168.3.250:50052,192.168.3.200:50052`:

- RPC0 = P40 (22.9 GB), RPC1 = GTX 1060 (6 GB), RPC2 = gpu-vm RAM (62 GB)
- RPC3 = RTX 5080 (15.8 GB), RPC4 = asusg16 RAM (62 GB)
- RPC5 = RX 5600XT, RPC6 = RX 560, RPC7 = 7700k RAM (62 GB) (RPC5/6 unused, see below)

**The tensor-split values must sum to n_layers + 1** (44 here, the extra slot is
the output layer). Summing to 43 shifts every device boundary by one layer and
over-allocates buffers (e.g. the 5080 got 5 layers = 17.9 GiB > its 15.8 GiB).

## Launch (client, on nixos-gpu-vm)

```bash
llama-server --host 0.0.0.0 --port 8080 \
  --model /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --ctx-size 8192 \
  --rpc 192.168.3.103:50052,192.168.3.250:50052,192.168.3.200:50052 \
  --device RPC3,RPC0,RPC1,RPC2,RPC4,RPC7 \
  --tensor-split 4,6,1,15,12,6 \
  --n-gpu-layers 99 -t 8 \
  --no-kv-offload --fit off --no-ui
```

Interactive shell:

```bash
llama-cli --model /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --rpc 192.168.3.103:50052,192.168.3.250:50052,192.168.3.200:50052 \
  --device RPC3,RPC0,RPC1,RPC2,RPC4,RPC7 \
  --tensor-split 4,6,1,15,12,6 \
  --n-gpu-layers 99 -t 8 --no-kv-offload --fit off \
  -cnv
```

(`-cnv` is the interactive conversation REPL for llama-cli; `-i` is
completion-only in b10133 and will be rejected. Add `-mli` for multiline
paste. Each client process re-streams its own copy of the model (~20 min).)

## Workers

- gpu-vm: `llama-rpc-server -H 0.0.0.0 -p 50052 -d CUDA0,CUDA1,CPU -t 32`
  (CUDA0 = P40, CUDA1 = 1060 — checked via `--list-devices`)
- asusg16: `llama-rpc-server -H 0.0.0.0 -p 50052 -d CUDA0,CPU -t 12`
- 7700k: systemd service `llama-rpc` (`services.llamaRpc.enable`, see
  `modules/services/llama-rpc.nix`): `llama-rpc-server -H 0.0.0.0 -p 50052 -d Vulkan2,Vulkan1,CPU -t 8`
  (Vulkan0 = Intel iGPU, Vulkan1 = RX 560, Vulkan2 = RX 5600XT)

## Critical gotchas (2026-08-09)

1. **`--fit off` is mandatory.** The default `--fit on` pass sabotages the
   RPC device registration: the fit's probe run drops remote devices so their
   buffers are never allocated (AMD GPUs + 7700k RAM stayed empty, weights for
   those layers silently went to the wrong devices).
2. **`--no-kv-offload` avoids the `[create_node] invalid data ptr` crash** on
   the first decode (RPC + Blackwell/Pascal cross-arch bug, see
   ggml-org/llama.cpp#21006 / #21030). With default KV offload the asusg16
   server dies with `[create_node] invalid data ptr` -> client aborts.
3. **AMD GPUs (RX 5600XT / RX 560) via Vulkan produce garbage tokens** with
   MXFP4 in b10133 (repeated "<" / word salad). They are excluded from the
   device list; the 7700k still contributes its CPU/RAM. This is why the
   package was switched from ROCm 5.7 (b4140) to Vulkan: modern llama.cpp
   requires ROCm >= 6.1 which dropped gfx803, and b4140 predates MXFP4.
4. **Tesla P40 needs active cooling.** Passive 250 W card; without airflow it
   thermal-drops off the PCIe bus (Xid 79, config space 0xFFFF) under load.
   Fixed by power cycling the host and adding airflow.
5. `pkill -f llama-server` matches the invoking shell itself (pattern in its
   own cmdline) — use `pkill -x` or kill by PID.
6. The llama-server client stdout is block-buffered when not a TTY; use
   `stdbuf -oL -eL` to see progress live.
7. Per-layer weights are uniform (3.33 GiB); the gguf file order is NOT by
   layer index (tensors are grouped by type across layer ranges), so "RAM
   stress" appears in a scrambled order during load — normal.

## Measured latency (2026-08-09, ctx 8192, batch 1)

- Generation: **~940-980 ms/token** (~1.05 tok/s); prompt processing: ~320-380 ms/token.
- Per token the 43 layers run strictly sequentially through the device groups:
  GPU layers (5080 4 + P40 6 + 1060 1) finish in **~10-20 ms** (GPUs show 0%
  util during generation - they idle waiting for the CPU layers).
- The **32 CPU layers are the bottleneck**: gpu-vm CPU (15 layers) ~40-50% of
  token time, asusg16 CPU (12) ~35%, 7700k CPU (6 incl. output) ~15%. The
  mxfp4 CPU decode is memory-bandwidth-bound and uses few cores (loadavg
  during generation: gpu-vm ~5/40, asusg16 ~1/16, 7700k ~0.6/8).
- Network: 5 device hops per token x ~2.5 ms LAN RTT ~= 12 ms (~1%).
- To make it faster: reduce CPU-resident layers (more VRAM), or accept lower
  quality on the AMD GPUs (they currently produce garbage with mxfp4).

## Config changes in this repo- `packages/llama-cpp-rpc.nix` — llama.cpp b10133 built with Vulkan + RPC
  (was ROCm 5.7.1/b4140). ROCm 5.7 packages stay in the 23-11 input.
- `modules/services/llama-rpc.nix` — systemd service for the 7700k RPC server
  (Vulkan device list, CPU threads, opens firewall port).
- `hosts/nixos-intel-7700k/default.nix` — `services.llamaRpc.enable = true`,
  devices Vulkan2,Vulkan1,CPU.
- `hosts/nixos-intel-7700k/packages/default.nix` — llama-cpp-rpc via current
  pkgs, mesa + vulkan-loader added, rocm-570/rocminfo kept.
- `hosts/nixos-gpu-vm/packages/default.nix` — python3 + numpy for gguf tooling.
