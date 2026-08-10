# llama.cpp RPC cluster — follow-up session 2026-08-10 (DSpark, KV-offload, quant swap)

Status: **~1.14 tok/s achieved (was 1.0), root cause of the network wall
identified to the tensor level. 5-10 tok/s is NOT achievable on this
topology for this model — see the "final wall" section.**

This file is the complete record of the second optimization session. Read
`llama-cluster-handoff.md` first for the topology, bring-up procedure and the
CPU-kernel analysis. This session's conclusion changes the story: the CPU
kernel is NOT the only (or main) wall anymore — the network is.

## 0. TL;DR

- Upgraded llama.cpp b10133 → **b10331** on all 3 machines (adds DeepSeek V4
  **DSpark** speculative decoding, PR #25784, merged Aug 2 2026).
- Fixed 2 upstream bugs we hit along the way (both still present in master):
  - `common/speculative.cpp:2336` loaded the **target** model as the draft
    (`params.model.path` instead of `model_path`) — the DSpark draft GGUF was
    never actually used.
  - `--spec-draft-device none` produces a `[nullptr]` device list which the
    model loader treats as "empty" but still builds CPU bufts for **all**
    registered CPU-type devices — including the RPC servers' CPU devices.
    Workaround: omit `--spec-draft-device` and use `--spec-draft-ngl 0`.
- Diagnosed the KV-offload-over-RPC crash (`[create_node] invalid data ptr`)
  to the tensor level with a debug patch: the culprit is
  `dsv4_csa_state_kv_lN` — the DSV4 **compressed attention states are
  sequential across layers** (layer N's state is consumed by all later
  layers), so with KV offload they land on one server's buffer while other
  servers' graphs reference them → cross-server refs → crash.
- Fix: keep the csa/hca/lid compressor **states** in client RAM
  (`packages/patches/rpc-dsv4-compressed-cpu.patch`), offload only the
  per-layer SWA window cache. KV-offload now works end-to-end: **1.14 tok/s**
  (was 1.0).
- DSpark works (loads, serves, no crash) but is a **net loss on 1 GbE**:
  the verification passes ship the F32 compressed states per pass, and the
  traffic balloons to ~160-172 MiB/token → 0.7-0.74 tok/s.
- The unsloth **UD-Q4_K_XL** quant (155 GB) makes the CPU 3-4x faster (server
  duty 10-14%) but the network grows to 44 MiB/token → 0.85 tok/s. Not the
  answer either.

## 1. The final wall (measured to the tensor level)

The per-token RPC traffic (~30 MiB/token at batch 1) is dominated by the
**DSV4 compressed attention states**, shipped from the client to the servers
as SET_TENSOR payloads on every pass (tcpdump + RPC-framing analysis):

| tensor | size | note |
|---|---|---|
| `dsv4_hca_state_kv_lN` / `dsv4_hca_state_score_lN` | **12 MiB each** | F32 `[12288, 64, 4]` (hc_mult x n_embd) |
| `dsv4_csa_state_kv_lN` / `score` | 1.5 MiB each | F32 |
| SWA window (`cache_k_lN` views) | 128 KiB each | q8_0 (K-only) — offloadable |
| graph structs (GRAPH_COMPUTE) | ~235 KiB each | re-sent when the graph structure changes (spec decoding) |

The hca/csa states are **F32, hardcoded at
`ggml/src/ggml-cpu/../llama-kv-cache-dsv4.cpp:913`** (`GGML_TYPE_F32`) — the
`-ctk/-ctv` flags cannot touch them, and quantizing them requires kernel
changes (the DSV4_HC_* ops read them as floats). They are sequential across
layers, so they cannot live on a single RPC server (cross-server refs crash
rpc-server) — they must be client-side and shipped.

At ~100 MiB/s effective (1 GbE), the baseline's ~30 MiB/token costs ~300 ms;
DSpark's batch-5 verification passes cost 5.6x more traffic (~160
MiB/token) because each pass re-ships the states for the whole batch window
plus the graph (structure changes per pass → graph-cache misses). The CPU
and the client (~150 ms graph build for 43 DSV4 layers) fill the rest.

Measured results (ctx 8192, batch 1, greedy):

| config | tok/s | traffic/token |
|---|---|---|
| b10133 baseline (docs config, `--no-kv-offload`) | 1.00 | 28.4 MiB |
| **b10331 + kv-offload + states-CPU fix (recommended)** | **1.14** | 30.7 MiB |
| UD-Q4_K_XL quant, no spec | 0.85 | 44 MiB |
| DSpark (either kv mode) | 0.70-0.74 | 160-172 MiB |

Reaching 5-10 tok/s on this hardware for DeepSeek-V4-Flash would require:
- ~200 GB of GPU VRAM (model fully on GPUs), or
- 10 GbE+ between the machines (the ~500 MiB/pass state traffic would flow
  in ~0.4 s), or
- a model without the sequential compressed-state architecture.

## 2. What was changed (all committed, all 3 host repos)

- llama.cpp **b10331** on all hosts (nixpkgs llama-cpp override + the 7700k's
  llama-cpp-rpc Vulkan package), with `LLAMA_TOOLS_INSTALL=ON` (b10331
  installs the rpc-server as `ggml-rpc-server` only with it).
- `packages/patches/rpc-graph-cache.patch` (unchanged, still applied).
- `packages/patches/rpc-dspark-draft-path.patch` — upstream bug: draft model
  load used the target path.
- `packages/patches/rpc-dsv4-compressed-cpu.patch` — DSV4 csa/hca/lid
  compressor states stay client-side (6 creation sites: kv_csa/kv_hca/kv_lid
  + csa_state/hca_state/lid_state); the per-layer SWA window cache still
  offloads. Enables KV offload over RPC.
- `packages/patches/rpc-debug-tensor-name.patch` — diagnostic (names the
  offending tensor in `create_node`/`deserialize_tensor`). Kept: it turns
  future "invalid data ptr" crashes into something diagnosable.

## 3. How to bring it up (2026-08-10, recommended config)

Servers unchanged (b10331, same commands as before). Client:

```bash
llama-server --host 0.0.0.0 --port 8080 \
  --model /home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-00001-of-00002.gguf \
  --ctx-size 8192 \
  --rpc 192.168.3.103:50052,192.168.3.250:50052,192.168.3.200:50052 \
  --device RPC3,RPC0,RPC1,RPC2,RPC4,RPC5 \
  --tensor-split 4,6,1,6,16,11 \
  --n-gpu-layers 99 -t 8 -lv 1 --fit off --no-ui \
  -ctk q8_0 -ctv q8_0
```

Notes vs the old config:
- **Drop `--no-kv-offload`** (KV offload now works — the states-CPU patch).
  This was a ~14% gain. `--tensor-split` is 4,6,1,6,16,11 (44 total): 6
  RAM layers on gpu-vm instead of 15 — gpu-vm's 60 GB RAM cannot hold the
  old 15 layers + the DSpark draft (OOM-killed the server; see gotchas).
- DSpark (if you want to try despite the network loss):
  `--model-draft /home/tianyixia/DeepseekV4-Flash-20260731-DSpark.gguf
  --spec-type draft-dspark --spec-draft-n-max 5 --spec-draft-ngl 0`
  (10.9 GB, downloaded via hf-mirror). Expect ~0.7 tok/s on 1 GbE.

## 4. New operational gotchas (2026-08-10)

- **gpu-vm OOMs when its rpc-server holds 15 RAM layers + the client's DSpark
  draft** (60 GB total). Rebalance CPU layers to asusg16/7700k (see the
  tensor-split above). The OOM kill: "oom-kill ... task=llama-rpc-serve".
- **Never pkill -f with a pattern that appears in your own command line**:
  `pkill -f "llama-server --host"` (or any pattern containing the launch
  text) kills the invoking shell/ssh session. Use `pkill -f "llama-serve[r]"`
  bracket tricks or kill by PID — and never put the pkill and the launch in
  the same command.
- **Rebuilding a machine kills the running client's connection to it**
  (systemd restarts the llama-rpc service on switch). Don't rebuild while a
  client is serving.
- **sudo-lock daemons die** (gpu-vm's died mid-session; `[sudo-env] no
  sudo-lock daemon active`). Refresh with `sudo-lock` on the machine.
- **gpu-vm /nix/store is a read-only btrfs mount** — you cannot extract store
  paths into it by hand; use git + nixos-rebuild (with `--impure`: the flake
  references `/etc/nixos/local.nix`).
- **git pull on the remote machines fails** when the default route/DNS is the
  wrong gateway; run `sudo-env -c 'bash ~/nixos-config/route-gateway.sh
  192.168.3.1'` (git) or `...192.168.3.2` (rebuilds) first.
- The client's `--log-file` produced ~0 bytes during normal operation in
  b10331 (only errors landed). For server-side forensics use the server logs
  and tcpdump (`nix shell nixpkgs#tcpdump`); the debug patch logs foreign
  buffers with tensor names.
- DSpark + `--spec-draft-device CPU` is rejected ("invalid device: CPU" —
  CPU devices are excluded from device lists); `none` silently scatters the
  draft's tensors over the RPC CPU devices and crashes at context init.
  Use `--spec-draft-ngl 0` instead.
- The DSpark draft GGUF (am17an/DeepseekV4-Flash-20260731-DSpark, 10.9 GB,
  `dflash` arch, block_size 5, 81 tensors incl. `markov_w1/w2`) is required —
  the 0731 MXFP4 GGUF does **not** embed the DSpark module (checked tensor
  names).

## 5. Session tooling that worked

- RPC message-level traffic analysis: tcpdump on the client
  (`port 50052 -w cap.pcap`), then python reassembly of the
  `|cmd(1)|size(8)|payload|` framing; SET_TENSOR payloads start with the
  rpc_tensor struct (name at offset 228, then offset(8) + data).
- The gguf header parser (python struct) for tensor-name scans of 2-part
  GGUFs (part 1 holds all metadata + 0 tensors; part 2 holds the 1328
  tensor infos).
- `nix build --impure --expr` for one-off llama.cpp builds against the
  channel nixpkgs; the flake's nixpkgs src hash must match for config
  rebuilds (the flake's own source is fetched on demand).

## 6. UPDATE (2026-08-10 late): the server-side 8x8 repack works — CPU no longer the wall

`packages/patches/rpc-server-repack.patch` (3 files):

1. `ggml/src/ggml-cpu/repack.cpp` — export `ggml_backend_cpu_repack_tensor()`
   (optimal-repack traits + in-place 8x8 repack + `tensor->extra` tag); the
   extra-buft's `get_tensor_traits` also accepts `extra`-tagged tensors (the
   plain CPU buft never sets `extra`, so this is unambiguous).
2. `ggml/src/ggml-rpc/ggml-rpc.cpp` — in `rpc_server::set_tensor`, when a full
   MXFP4 weight arrives (offset==0, size==nbytes), repack it in place instead
   of the raw write. Resolves the repack entry point with `dlsym(RTLD_DEFAULT)`
   (a link-time reference would break libggml-rpc.so loading — the CPU
   backend lib is dlopen'd RTLD_LOCAL).
3. `ggml/src/ggml-backend-dl.cpp` — dlopen backends with `RTLD_GLOBAL` so the
   dlsym resolves.

This is exactly what upstream says is "unusable on RPC servers" (the client
cannot know the remote hardware) — done on the server instead, where the
hardware IS known. Falls back to the unrepacked path for non-repackable
tensors (ne[1] % 8 != 0).

Measured effect (kv-offload config, generation): **asusg16's CPU duty during
generation dropped 12.4% -> 3.7%** (~3x faster CPU layers on the 16-layer
machine) with correct output. The per-token time stayed 1.14 tok/s because
the wall is now the network + client:
- network: ~30 MiB/token (~300 ms) — the DSV4 F32 compressed states
- client: ~150-200 ms graph build for the 43-layer compression machinery
- CPU layers: ~100-150 ms (was ~420 ms)
- GPU layers: ~20 ms

So: the mxfp4 dequant latency chain (not ALU, not DRAM) WAS the CPU wall —
the repack removed it. What remains is architectural (sequential F32 states
on 1 GbE) and fixed cost (client graph build). Levers left: `-np 1` shrinks
the state planes 4x (n_planes = n_seq_max); 10GbE; more VRAM.

## 7. FINAL measured state (2026-08-10, careful re-benchmark)

Cluster serving: b10331 + all patches (graph-cache, dspark-path, debug,
states-CPU, server-side 8x8 repack), kv-offload ON, tensor-split
4,6,1,6,16,11, ctx 8192, 3 x 100-token runs, greedy, same prompt:

| metric | value |
|---|---|
| generation | **1.07-1.11 tok/s (897-935 ms/token)** |
| prompt processing | 1.85-2.14 tok/s |
| traffic | ~31 MiB/token (3066-3104 MiB per 100-token run) |
| client CPU | **53 ms/token** (utime+stime, /proc/PID/stat) |
| server CPU duty (asusg16, gen) | ~3.7% (was 12.4% pre-repack) |

Corrected per-token budget (~910 ms):

| component | ms | evidence |
|---|---|---|
| network (DSV4 F32 states + window, 31 MiB) | ~310 | NIC deltas @ ~100 MiB/s |
| CPU layers (repacked 8x8) | ~100-150 | duty-based |
| client (graph build + KV + sampling) | ~53 | measured |
| GPU layers | ~20 | |
| **sum** | ~480-530 | |
| **pipeline serialization slack** | **~380-430** | RPC splits run strictly serially: copy(N) -> compute(N) -> copy(N+1); transfers never overlap computes; each split also pays an RTT |

The old "client ~150-200 ms" estimate was wrong (pre-graph-cache measurement);
the client is ~53 ms/token. The big slack is the serialized pipeline: the
states transfer (~100 ms per server) and the server compute (~40 ms per
server) are added, not overlapped.

### What was tried and its verdict
- mxfp4 CPU kernel: fixed via the server-side 8x8 repack (12.4% -> 3.7% duty;
  the kernel now runs at ~55-80% of the ~82 ms bandwidth-saturated floor).
- UD-Q4_K_XL quant: slower (0.85 tok/s; bigger states -> more traffic).
- DSpark: works (loads/serves) but loses on 1 GbE (batch-5 pass traffic
  balloons to ~160 MiB/pass; the states dominate).
- KV-offload: fixed (states-CPU patch), +14% over the old config.
- `-np 1` (states 4x smaller): NOT measured (session ended) - expected
  ~1.5-1.8 tok/s on 1 GbE; irrelevant once 40GbE arrives.
- Async-RPC pipelining (overlap transfers with computes): analyzed, not
  implemented. Worth ~1.5-2x on 1 GbE; pointless on 40GbE.

### 40GbE plan (hardware on order)
- The pipeline serialization is network time: the transfers are the long
  poles. 40GbE (~4-5 GB/s) shrinks the per-split transfer to ~2-3 ms.
- Expected: token ~200 ms -> **~5 tok/s** without DSpark; **~4-7 tok/s**
  with DSpark (the states become cheap, batch-5 amortizes the dense reads).
- Setup: client <-> each server directly (or a small switch; the client's
  single 40GbE port is the aggregate pipe), MTU 9000 jumbo frames,
  static routes for the 50052 traffic (route-gateway.sh pattern).
- llama.cpp RPC has an RDMA path (GGML_RPC_RDMA) if TCP is later a limit.
- With the network gone, the remaining walls: CPU sum (~120 ms -> ~30-60
  ms with DSpark) and the client (~53 ms).
