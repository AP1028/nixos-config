#!/usr/bin/env bash
# Stop vLLM servers managed by launcher.sh under ~/vLLM-2080Ti-Definitive.
set -euo pipefail

RUNTIME="${RUNTIME_ROOT:-$HOME/vLLM-2080Ti-Definitive}"
LOG_DIR="$RUNTIME/run-logs"

for pid_file in "$LOG_DIR"/*.pid; do
  [ -f "$pid_file" ] || continue
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] || continue
  if [ -d "/proc/$pid" ]; then
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" == *"vllm.entrypoints.openai.api_server"* ]]; then
      pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
      if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
    fi
  fi
done

sleep 8
pkill -TERM -f "$RUNTIME/.venv/bin/python -m vllm.entrypoints.openai.api_server" 2>/dev/null || true
sleep 3
pkill -KILL -f "VLLM::" 2>/dev/null || true
echo "vLLM Qwen stopped."
