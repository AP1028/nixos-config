# Qwen3.8-Flash-Next (qwen4exp) on the GPU VM — research plan

Status: drafted 2026-08-27, not started. Pick up when llama.cpp PR #27742 matures.

## Goal

Run Qwen3.8-Flash-Next (125B main / 6B active MoE, 51B n-gram PLE, 4B MTP) with
**>256K context (ideally 1M)** on existing hardware: 2× 22G-modded 2080Ti (Turing sm_75,
~616 GB/s each) + 1× P40 24G (Pascal sm_61, 346 GB/s) = **68 GB VRAM total**, EPYC 7002
host (8ch DDR4, ~150 GB/s effective RAM, Gen3 PCIe links).

## Model facts

- Arch: `qwen4_exp` (`Qwen4ExpForConditionalGeneration`), multimodal, 48 layers
- 12 × (3× [Gated DeltaNet → MoE] → 1× [Qwen Sparse Attention → MoE])
- 512 routed experts (10 active/token) + 1 shared expert
- N-gram embedding: 20M-entry table, 51B params, used only at layer 2 (lookup, KBs/token)
- Context: 262,144 native, 1M via YaRN (unvalidated in llama.cpp)
- KV cache: ONLY the 12 QSA layers have KV (~24.6 KB/token f16) + indexer key cache
  (~6.1 KB/token) → ~30.7 KB/token total
- Native release is BF16 (360 GB on HF). NOT FP4-trained → re-quantization is fine.

## Key decisions (from analysis)

1. **Quantization**: custom per-tensor mix via `llama-quantize --tensor-type`:
   - QSA/DeltaNet attention + router + shared expert: Q5_K/Q6_K (quality-critical)
   - Routed experts: Q4_0 baseline, or **IQ2_XS (imatrix) if context >~400K needed**
     (experts are ~95% of params; MoE tolerates low bpw, but 6B active = less redundancy
     than DeepSeek-R1 → expect noticeable quality drop at Q2, esp. agentic coding)
   - PLE table: Q8+, RAM-resident (`--override-tensor per_layer_token_embd=CPU`)
2. **KV stays 100% in VRAM, f16** (q8 KV on QSA currently produces garbage; watch the PR)
3. **Weight→RAM offload only for GDN layers / experts** (`--n-cpu-moe` or `--override-tensor`):
   - Never offload QSA layers (KV follows compute device → RAM KV = context-proportional
     per-token reads, ~40 ms/token @ 256K — catastrophic)
   - Never offload MTP weights while speculation is on (2 GB/token/step)
4. **Prefill vs decode are different regimes**:
   - Decode: bandwidth-bound; spilled GDN layer ≈ 0.6-0.7 ms/token (RAM 150 GB/s vs VRAM)
     → proportional tax (~15-20% per few GB spilled)
   - Prefill: FLOP-bound; CPU (AVX2 fp32, no AVX-512/VNNI on Zen2) is the wall.
     CPU prefill @ spill: ~spill% × 12 GFLOPs/token × ctx ÷ CPU_TFLOPs.
     MEASURED 7F72 capability: ~0.93-0.97 TFLOPs effective (llama-8B F16 pp512=58.3
     t/s; Mixtral-8x22B Q8 pp=12.4 t/s). So: whole-model CPU prefill ~80-100 tok/s;
     50% expert-only spill ~400-430 tok/s (experts ≈ 39% of active FLOPs).
5. **Spill-free ceiling on 68 GB** (f16 KV, ~3 GB overhead):
   - Q3_K_S (54.7 GB): ~336K ctx — fully resident, prefill ~10-20 s, decode ~450 tok/s
   - IQ3_XXS (51.6 GB): ~437K ctx
   - Q2 mix (40.5 GB): 768K ctx resident; 1M needs ~6 GB spill (10%)

## The fork idea: streaming prefill (idea is PROVEN; integrate, don't invent)

Problem: at 1M ctx, any weight spill forces 20 min - 2.5 h CPU prefill.
Idea: during prefill only, stream spilled tensors to a GPU scratch buffer per chunk
(`cudaMemcpyAsync`, pinned host memory) and compute on tensor cores; during decode keep
computing spilled weights on CPU (latency-bound, CPU is fine).

**2026-08-27 update: this is already implemented elsewhere. Do NOT write from scratch.**

- llama.cpp PR **#25294** / `ServeurpersoCom:moe-stream-partition` — RAM→VRAM expert
  streaming, all compute on GPU, wave-partitioned prefill (expert loaded once per
  ubatch, misses slip behind shared expert). +77% prefill / +50% decode vs --n-cpu-moe
  on DeepSeek-V4-Flash 284B. Flags: `--moe-stream-cache`, `--moe-stream-direct`.
  Limitation: single-context only.
- llama.cpp PR **#26824** (WackMall) — heatmap expert cache, expert-level granularity,
  device-priority placement (hot→best GPU, cold→weak GPU: USE for P40 tier),
  mmap pinning, copy/move modes, sidecar heatmap, hash-verified swap.
  Flags: `-ehs N`, `--expert-sidecar`, `--expert-move-mode`. Multi-GPU untested.
- RFC **#24528** + issue **#20757** — SLRU + admission-filter expert cache;
  key finding: fill cache during DECODE only (prefill routing is flat and thrashes
  caches) — validates the phase-split policy. +26% decode / +55% prefill (Vulkan).
- **Lidenburg/llama.cpp** fork — three-tier GPU/RAM/disk (io_uring+O_DIRECT), LFU aging.
- arXiv **2606.10493** — Stream-Loading Prefill (SLP): loader/model/unloader
  three-stream pipeline + expert ring buffer, ring length adapts to transfer-vs-compute
  balance. 1,200 tok/s prefill, 32K prompts in 30 s. Formalization of this exact idea.
- KTransformers v0.6.4 — now SGLang-based (sglang-kt), 1M-ctx recipe on 4×5090,
  layerwise GPU prefill + dynamic expert update — but NO qwen4exp support and
  SGLang/FlashInfer excludes P40 (sm_61). Watch for qwen4exp/Qwen4 support.

Plan change: fork = qwen4exp PR #27742 + adapt streaming machinery from #25294/#26824.
Integration risk, not invention risk.

- t_stream = W_spilled × chunks ÷ ~30 GB/s (3 Gen3 links)
- 6 GB spill @ 1M: chunk 512 → ~6.5 min, chunk 2048 → ~1.6 min, chunk 4096 → ~50 s
  (NOTE: at any chunk ≥512, routing picks touch ~all experts → whole spilled set per chunk;
  bigger ubatch is the only lever)
- 32 GB spill @ 1M: chunk 2048 → ~8.7 min (vs 1-2.5 h CPU)
- GPU compute portion @ 1M: ~1 min on 2080Ti INT8 tensor cores (~200-250 TOPS eff);
  **P40 is a prefill drag (~26 TOPS dp4a, no tensor cores) → keep its layer share lean,
  QSA layers on 2080Tis**
- Total estimate 1M @ Q2 mix + 6 GB spill: **~2.5-5 min prefill** (streaming-bound),
  decode ~300 tok/s (2.5 GB/token reads at Q2)
- Precedent: KTransformers (expert prefetch to GPU, decode-focused), vLLM/SGLang expert
  offload (serving-focused); nobody does per-chunk prefill weight streaming.

## Baseline build & run (today)

- llama.cpp PR: **#27742** "model: add Qwen3.8-Flash-Next (qwen4exp)" (unslothai fork).
  Competing PR: #27739 (has MTP + PLE offload). Feature issue: #27741.
  Known issues: #27763 (garbage >8 GPU layers = CUDA 13.0.88 toolkit fix; 13.2 broken).
- GGUFs: `unsloth/Qwen3.8-Flash-Next-GGUF` (UD-IQ4_XS 93.7 GB etc.)
- Build: CUDA archs `75;61` (Turing + Pascal), `GGML_CUDA_FA=ON`.
  Fallbacks: `GGML_CUDA_PDL=0`, `LLAMA_ATTN_ROT_DISABLE=1`.
- Run flags: `--override-tensor per_layer_token_embd=CPU` (PLE to RAM, mmap),
  `--cache-type-k f16 --cache-type-v f16`, `--spec-type ngram-mod` (MTP is WIP),
  `--n-cpu-moe N` if spilling experts, `--ubatch-size` 2048-4096 when streaming lands.
- Verification discipline: compare output against `-ngl 0` CPU baseline (garbage-without-
  crash is the classic failure mode on this arch).

## Open questions / watch list

- [ ] QSA quantized KV (q8) — PR has support commit; reports say garbage. If fixed,
      KV halves → 1M becomes resident at Q2 (no spill, no streaming needed)
- [ ] MTP in #27742 or #27739 (sidecar GGUF approach exists, correctness unverified)
- [ ] YaRN at 1M on qwen4exp — unvalidated; test before trusting 1M outputs
- [ ] Q2 quality on real workload (A/B vs Q3_K_S at equal context)
- [ ] P40 in the mix: consider whether it should be swapped (more 22G 2080Ti) if
      prefill matters
- [ ] Watch #25294 / #26824 merge status — if either lands upstream, port cost drops
      to nearly zero
- [ ] #25294 is single-context only — verify multi-session behavior before relying
      on it for serving

## Implementation order (fork — integration, not invention)

1. Q2 mix + `--n-cpu-moe` + chunked prefill → measure CPU prefill split (100K smoke test)
2. Base fork on qwen4exp PR #27742; cherry-pick/adapt expert-streaming from #25294
   (prefill) + #26824 (heatmap/device-priority) — expect conflict work in
   ggml-backend scheduler + MUL_MAT_ID paths; verify qwen4exp graph compat
3. P40 as the "cold" tier via #26824 device-priority placement (hot→2080Ti, cold→P40)
4. Measure: streaming fork prefill ≥3x vs CPU prefill at same ctx (success metric)
5. Decode-only cache fill (per RFC #24528) + ngram-mod speculation

## Cost summary of the whole plan

- Existing hardware, $0 hardware: ≤~400K ctx (Q3/Q2 resident), or 1M with Q2 + spill +
  streaming fork (~3-8 min prefill, ~300 tok/s decode, Q2 quality caveat)
- The cable-box option (6× riser / slot-to-slot, ~132 GB): everything resident,
  450+ tok/s, ~1 min prefill — revisit only if quality-at-Q2 fails
