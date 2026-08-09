# llama.cpp RPC cluster — full handoff / problem report

Status: **working cluster, ~1 tok/s, bottleneck root-caused and documented.**
This file is the complete record for a follow-up session that wants to make
it faster.

## 1. Goal

Run DeepSeek V4 Flash (MXFP4, ~144 GiB, 43 layers x ~3.33 GiB) as an
llama.cpp RPC cluster over 3 machines (1 GbE), with a specific memory fill
order (GPUs first, then RAMs). Understand and fix why the CPU-resident
layers are slow (<10% memory bandwidth utilization).

## 2. Topology (current, working)

| Host | IP | Role | Layer split (tensor-split 4,6,1,15,12,6) |
|---|---|---|---|
| `nixos-gpu-vm` | 192.168.3.103 | **client** (llama-server, holds the model) + worker | P40 6 layers, GTX 1060 1 layer, RAM 15 layers |
| `asusg16` | 192.168.3.250 | worker | RTX 5080 4 layers, RAM 12 layers |
| `nixos-intel-7700k` | 192.168.3.200 | worker (CPU/RAM only) | RAM 6 layers (incl. output) |

Model: `/home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-0000{1,2}-of-00002.gguf`
(2-part split). Architecture `deepseek4`: 43 layers, n_embd 4096, 256 experts
(top-6 + 1 shared), MLA attention with 128-token sliding window, DSV4
"hc"/csa compressor state.

Fill order via `--device RPC3,RPC0,RPC1,RPC2,RPC4,RPC5`:
RPC0=P40, RPC1=1060, RPC2=gpu-vm RAM, RPC3=5080, RPC4=asusg16 RAM, RPC5=7700k RAM.
(AMD GPUs were physically removed; the 7700k server exposes only its CPU via `-d CPU`.)

## 3. How to bring it up

```bash
# 7700k (systemd, config-managed):
systemctl start llama-rpc        # llama-rpc-server -d CPU -t 8 (from services.llamaRpc)

# asusg16 (manual, nohup):
llama-rpc-server -H 0.0.0.0 -p 50052 -d CUDA0,CPU -t 16

# gpu-vm (manual, nohup):
llama-rpc-server -H 0.0.0.0 -p 50052 -d CUDA0,CUDA1,CPU -t 32

# client (gpu-vm, model must be loaded ~20 min):
llama-server --host 0.0.0.0 --port 8080 \
  --model /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --ctx-size 8192 \
  --rpc 192.168.3.103:50052,192.168.3.250:50052,192.168.3.200:50052 \
  --device RPC3,RPC0,RPC1,RPC2,RPC4,RPC5 \
  --tensor-split 4,6,1,15,12,6 \
  --n-gpu-layers 99 -t 8 -lv 1 --no-kv-offload --fit off --no-ui
```

**MANDATORY flags** (all discovered the hard way):
- `--fit off` — the default fit-params pass sabotages RPC device
  registration (devices silently dropped).
- `--no-kv-offload` — kv-offload crashes ANY rpc-server with
  `[create_node] invalid data ptr` (cross-arch RPC bug, unfixed upstream;
  issue #21006 / PR #21030).
- `--tensor-split` values must sum to n_layers+1 (44) or every device
  boundary shifts by one layer (over-allocates buffers, OOM).
- Client stdout is block-buffered; use `stdbuf -oL -eL`.

Per-token traffic: ~25-33 MiB (mostly the KV sliding-window shipping, a
`--no-kv-offload` consequence: 1024-dim x 128-token x fp16 x 43 layers).

## 4. What was done and why (chronological)

1. **Brought up the cluster** with a fill order via `--device` + `--tensor-split`.
2. **AMD GPUs (RX 560 / RX 5600XT)**: produced garbage tokens with MXFP4 on
   the Vulkan backend in b10133 (repeated "<"). Physically removed; the 7700k
   is CPU/RAM only. (This is also why the custom Vulkan build exists:
   b4140/ROCm 5.7.1 predates MXFP4, and modern llama.cpp needs ROCm >= 6.1
   which dropped gfx803.)
3. **Graph-serialization fix** (`packages/patches/rpc-graph-cache.patch`,
   applied on all 3 machines): the scheduler assigned a fresh `uid` to every
   split graph on every compute (`ggml_backend_sched_split_graph`), so the
   RPC `GRAPH_RECOMPUTE` cache never engaged and the client re-sent the full
   graph topology every token. Fix: derive the split uid from a hash of the
   graph structure (node/leaf pointers + counts). Result: traffic dropped
   ~8 MiB/token, token time unchanged (network was hidden behind the CPU).
   ~2-4% gain.
4. **Repack patch REVERTED**: tried to make rpc-servers repack mxfp4 weights
   (the fast 8x8 GEMV path) via the CPU repack buffer type. It (a) crashed
   the server (SIGSEGV in `ggml_backend_buft_get_alignment`, from the
   repack-buft proc-address lookup in `rpc_server_get_buft`) and (b) is
   against upstream design: maintainers explicitly said repacking is not
   usable on RPC servers (discussion #21130). The patch is removed from the
   configs (git history has it).
5. **CPU performance investigation** (the main problem): measured per-token
   CPU busy phases via 10ms `/proc` sampling and per-thread utime sampling,
   socket traffic via NIC counters, and RAPL package power.

## 5. THE ROOT CAUSE (the problem to fix)

**The mxfp4 GEMV kernel's throughput is the bottleneck, not the CPU count,
not the RAM, not the hypervisor.**

Direct microbenchmark (dlopen of the real `ggml_vec_dot_mxfp4_q8_0` from
each machine's `libggml-cpu-haswell.so`, 50000 rows of 4096):

| Machine | 1 thread | max threads | streaming peak |
|---|---|---|---|
| asusg16 (DDR5-7000) | 7.0 GB/s | **20.3** (16t) | 71 GB/s |
| gpu-vm (EPYC VM) | 4.7 | **12.4** (32t) | 105 GB/s |
| 7700k (DDR4) | 6.3 | **12.8** (16t) | ~50 GB/s |

- The kernel saturates at 12-20 GB/s everywhere: the 4-bit unpack + LUT
  dequant instruction mix limits each core to ~2-7 GB/s, and thread
  contention/latency caps the total.
- The RAM is fine (streams at 71-105 GB/s with a plain AVX2 read loop).
- The layers run at 4-7 GB/s (2-3x below even the kernel ceiling) due to
  op dispatch/barrier overhead, small MLA GEMMs, and the sequential DSV4
  compressor state.
- CPU duty cycle ~10-20% is consistent: ~1.3-1.6 core-seconds of work per
  token, mostly at poor per-thread efficiency.
- Token time ~1040 ms = the sum of the sequential CPU-layer phases
  (the layers cannot overlap across machines).
- RAPL package power during inference ~15-24 W vs ~75-81 W during a 71 GB/s
  streaming benchmark: the DRAM is genuinely not being hammered.

**Conclusion: ~1 tok/s is the kernel-limited expected result for this
topology. Nothing is misbehaving at the CPU/RAM/VM level.**

## 6. Possible fixes for a follow-up session

1. **The repack, done the upstream-friendly way**:
   - Upstream says repack is "tightly related to the underlying hardware"
     and unusable on RPC servers. BUT the repack *algorithm* could be
     applied on the rpc-server side after `SET_TENSOR` (weights arrive
     once at load). The 8x8 interleaved layout (`repack_mxfp4_to_mxfp4_8_bl`
     in `ggml/src/ggml-cpu/repack.cpp`) + `ggml_gemv_mxfp4_8x8_q8_0` would
     raise the per-core rate 2-4x. My failed patch tried the buffer-type
     route (crashed in `ggml_backend_buft_get_alignment`); a safer route:
     repack in-place in `rpc_server::set_tensor` (data is a separate
     network buffer, so no aliasing) and set `tensor->extra` traits so the
     fast path dispatches. Must handle: shared-buffer offsets (repack
     asserts offset==0), non-repackable types, and views.
   - NOTE: upstream's direction is the opposite (repack disabled by default,
     PR #19932, because it hurts hybrid CPU/GPU). The correct long-term fix
     is upstream RPC support; short-term a careful server-side repack patch
     is the only way to get the fast CPU path over RPC.
2. **Fewer CPU-resident layers** (more VRAM) — linear win, no patch needed.
3. **40GbE** — helps only after the CPU stops being the wall (~25-30% now).
4. **RPC protocol improvements** — upstream PRs are drafts only:
   #8032 (cross-server tensor copy, abandoned), #24122 (small-message
   overhead, draft), #22850 (metadata explosion analysis, no fix merged).
5. **The DSV4 compressor (csa_state) hypothesis**: the per-layer time is
   5x the raw kernel time; the sequential compressor state update may be a
   large single-threaded component. Profile per-op (server-side
   instrumentation in `rpc_server::graph_compute`, or a working 1-layer
   model for isolated benches) to confirm before optimizing elsewhere.

## 7. Known problems and gotchas (operational)

- **gpu-vm rpc-server crashes** (SIGSEGV in libggml-base or SIGABRT in
  `ggml_backend_buft_get_alignment`) when its GPU state is polluted
  (leftover VRAM from crashed clients, or after the P40 thermal event —
  Xid 79 "fallen off the bus", needs active cooling + power cycle). Fix: VM
  reboot. The SIGSEGV at libggml-base+0x1e265 also appeared in patched
  builds during the repack experiments; the clean builds are stable.
- **RPC servers are single-client with listen backlog 1**: stale
  connections from dead clients jam registration ("Failed to connect",
  "invalid device: RPC3"). Always kill ALL rpc-server processes and verify
  `ss -tln | grep 50052` before starting a client.
- **`pkill -f llama-server` matches the invoking shell** (pattern in its
  own cmdline) — use `pkill -x` / kill by PID.
- **7700k network**: the NIC's PCI slot changed (enp7s0 -> enp3s0) — fixed
  in the config; the AMD GPU removal changed the PCI enumeration again —
  re-check interface names after hardware changes.
- **gpu-vm rebuilds** via `nixos-switch` (needs the sudo-lock daemon);
  asusg16 rebuilds need the user's kdialog/sudo-lock.
- All three config repos must be at the same commit before a cluster
  bring-up (the graph-cache commit 7462c29).

## 8. Measurement toolkit (scripts/methods used)

- Per-token server CPU busy phases: sample `/proc/PID/stat` utime+stime at
  10ms; group into busy phases. NOTE: process-level 10ms sampling
  under-reported the concurrency (per-thread sampling at 5ms is correct).
- Per-thread CPU: `/proc/PID/task/TID/stat` fields 14+15 at 5ms.
- Traffic: gpu-vm NIC `tx_bytes` deltas; `/proc/PID/io` does NOT count
  sendto/recvfrom.
- RAPL package power: `/sys/class/powercap/intel-rapl:0/energy_uj`
  (root-only), calibrated against the streaming benchmark.
- Kernel microbenchmark: `/tmp/opencode/vecbench.c` (dlopen
  `ggml_vec_dot_mxfp4_q8_0`, rows of 4096, 1..32 threads) — THE definitive
  tool for any kernel-performance question.
- Streaming bandwidth: `/tmp/opencode/bwmt.c` (multi-threaded AVX2 reads).
- 1-layer model extraction for isolated layer benches: attempted with
  gguf-py, fought the writer's conventions (dims reversed, byte vs element
  shapes, tokenizer KV drift, absolute vs relative offsets); NOT completed.
  The vecbench approach makes it mostly unnecessary.

## 9. Relevant upstream references

- llama.cpp discussion #21130 (repack / extra buffers not usable on RPC)
- llama.cpp issue #22850 (RPC metadata explosion / performance analysis)
- llama.cpp PR #8032 (RPC cross-server copy, draft/abandoned)
- llama.cpp PR #24122 (RPC small-message overhead, draft)
- llama.cpp issue #21006 / PR #21030 (RPC "invalid data ptr" / kv-offload)
- llama.cpp PR #19932 (repack disabled by default)
- llama.cpp PR #21764 (graph_reused) and #22041 (meta backend split cache)
- The kernel: `ggml/src/ggml-cpu/arch/x86/quants.c` (vec_dot_mxfp4_q8_0),
  `ggml/src/ggml-cpu/repack.cpp` (8x8 repack + gemv), and the scheduler
  uid logic in `ggml/src/ggml-backend.cpp`.
