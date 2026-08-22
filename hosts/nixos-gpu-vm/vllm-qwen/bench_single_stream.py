#!/usr/bin/env python3
"""Single-stream decode benchmark for vLLM Qwen3.8-27B-FP8 on gpu-vm.

Stdlib-only so it can run from the target host without extra Python deps.

Method:
  * one warmup request first (excluded from results)
  * N timed /v1/completions streaming requests
  * prefill t/s = prompt_tokens / time-to-first-token
  * decode  t/s = completion_tokens / (total_time - ttft)
  * VRAM/RAM sampled after the timed runs

Usage:
  python3 bench_single_stream.py [--url http://127.0.0.1:8000] \
      [--runs 3] [--max-tokens 128] [--no-warmup]
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
import urllib.request

# About 130 tokens for most Qwen tokenizers (actual count is reported by
# the server from the usage block).  One short paragraph, no special chars.
PROMPT = (
    "The small laboratory runs a weekly systems benchmark. "
    "Each Monday the team loads the language model, warms the CUDA graphs, "
    "and measures latency with a single client request. "
    "They record time to first token, generated tokens per second, "
    "GPU memory on each device, and host memory after the run. "
    "The results are written to a plain text report and compared with the "
    "previous week. "
    "Stable numbers come from repeating the same request three times after "
    "warmup. "
    "The team prefers short prompts for decode work and longer prompts only "
    "when prefill matters. "
    "This sentence pads the prompt to the planned token count. "
)


def request_once(base_url: str, model: str, max_tokens: int) -> dict:
    payload = {
        "model": model,
        "prompt": PROMPT,
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": False,
    }
    req = urllib.request.Request(
        base_url.rstrip("/") + "/v1/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t_start = time.perf_counter()
    ttft = None
    tokens = 0
    usage = {}
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
            if ttft is None and chunk.get("choices"):
                ttft = time.perf_counter() - t_start
                choice = chunk["choices"][0]
                # prompt usage may arrive in the first chunk
                if choice.get("usage"):
                    usage.update(choice["usage"])
            for choice in chunk.get("choices") or []:
                piece = choice.get("text") or ""
                if piece:
                    # Text is appended in the stream, so count completion
                    # tokens via the final usage block instead of len(piece).
                    pass
            if chunk.get("usage"):
                usage.update(chunk["usage"])
    t_end = time.perf_counter()
    total_s = t_end - t_start
    if ttft is None:
        ttft = total_s
    prompt_tokens = int(usage.get("prompt_tokens") or 0)
    completion_tokens = int(usage.get("completion_tokens") or 0)
    if prompt_tokens == 0 and ttft > 0:
        # Assume the requested prompt token budget is close to reality.
        prompt_tokens = 120
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "ttft_s": ttft,
        "total_s": total_s,
        "prefill_tps": prompt_tokens / ttft if ttft > 0 else float("nan"),
        "decode_tps": completion_tokens / (total_s - ttft)
        if total_s > ttft > 0
        else float("nan"),
        "ms_per_token": (total_s - ttft) / completion_tokens * 1000
        if completion_tokens and total_s > ttft
        else float("nan"),
    }


def gpu_memory_mib() -> list[tuple[str, str]]:
    try:
        out = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,name,memory.used,memory.total,utilization.gpu,power.draw",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        return [tuple(line.split(", ")) for line in out.splitlines() if line]
    except Exception as exc:  # pragma: no cover
        return [("?", f"nvidia-smi failed: {exc}", "?", "?", "?", "?")]


def host_memory_gib() -> float:
    try:
        out = subprocess.run(
            ["free", "-b"], capture_output=True, text=True, timeout=10
        ).stdout
        for line in out.splitlines():
            if line.startswith("Mem:"):
                parts = line.split()
                total = int(parts[1])
                available = int(parts[6])
                return (total - available) / 2**30
    except Exception:
        pass
    return float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os_env_or("VLLM_URL", "http://127.0.0.1:8000"))
    ap.add_argument("--model", default=os_env_or("VLLM_MODEL", "Qwen3.8-27B-FP8"))
    ap.add_argument("--runs", type=int, default=int(os_env_or("RUNS", "3")))
    ap.add_argument("--max-tokens", type=int, default=int(os_env_or("MAX_TOKENS", "128")))
    ap.add_argument("--no-warmup", action="store_true")
    args = ap.parse_args()

    if not args.no_warmup:
        print(f"warmup request -> {args.url}", flush=True)
        request_once(args.url, args.model, args.max_tokens)

    results = []
    for i in range(1, args.runs + 1):
        r = request_once(args.url, args.model, args.max_tokens)
        results.append(r)
        print(
            f"run {i}: prompt={r['prompt_tokens']} completion={r['completion_tokens']} "
            f"ttft={r['ttft_s']*1000:.1f}ms "
            f"prefill={r['prefill_tps']:.1f} tok/s "
            f"decode={r['decode_tps']:.1f} tok/s "
            f"total={r['total_s']:.2f}s",
            flush=True,
        )
        time.sleep(1.0)

    if not results:
        return 1

    medians = {
        "prompt_tokens": statistics.median(r["prompt_tokens"] for r in results),
        "completion_tokens": statistics.median(r["completion_tokens"] for r in results),
        "ttft_s": statistics.median(r["ttft_s"] for r in results),
        "prefill_tps": statistics.median(r["prefill_tps"] for r in results),
        "decode_tps": statistics.median(r["decode_tps"] for r in results),
        "ms_per_token": statistics.median(r["ms_per_token"] for r in results),
        "total_s": statistics.median(r["total_s"] for r in results),
    }
    print("\nMEDIAN:", json.dumps(medians, indent=2))

    print("\nGPU memory:")
    for row in gpu_memory_mib():
        print("  " + " | ".join(row))
    print(f"host used: {host_memory_gib():.1f} GiB")

    out = {
        "url": args.url,
        "model": args.model,
        "max_tokens": args.max_tokens,
        "runs": results,
        "medians": medians,
        "gpu_memory_mib": gpu_memory_mib(),
        "host_used_gib": host_memory_gib(),
    }
    with open("bench_single_stream.json", "w") as f:
        json.dump(out, f, indent=2)
    print("wrote bench_single_stream.json")
    return 0


def os_env_or(key: str, default: str) -> str:
    import os

    return os.environ.get(key, default)


if __name__ == "__main__":
    sys.exit(main())
