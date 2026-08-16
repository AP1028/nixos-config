#!/usr/bin/env bash
# Start vLLM Qwen3.8-27B-FP8 on gpu-host (2x RTX 2080 Ti, TP=2).
#
# Usage: run-vllm-qwen.sh [fast|balanced|peak]
#   fast     recommended daily profile: MTP4 + PIECEWISE graphs
#   balanced MTP3 (highest acceptance, slightly lower filler decode)
#   peak     MTP12 synthetic peak (~178 tok/s PP128/TG128 pure filler)
#
# The server keeps running after this script exits. Logs are under
# ~/vLLM-2080Ti-Definitive/run-logs/ and state in run-logs/start-manager.state.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${RUNTIME_ROOT:-$HOME/vLLM-2080Ti-Definitive}"
MODE="${1:-fast}"

case "$MODE" in
  fast)
    PROFILE_FILE="$HERE/profiles/qwen38-27b-fp8-fast-mtp4.env"
    ;;
  balanced)
    PROFILE_FILE="$HERE/profiles/qwen38-27b-fp8-fast-mtp3.env"
    ;;
  peak)
    PROFILE_FILE="$HERE/profiles/qwen38-27b-fp8-peak-mtp12.env"
    ;;
  *)
    echo "unknown mode: $MODE (use fast, balanced, or peak)" >&2
    exit 2
    ;;
esac

cd "$RUNTIME"
exec env \
  CUDA_HOME=/etc/vllm-cuda-home \
  LD_LIBRARY_PATH=/run/opengl-driver/lib \
  TRITON_LIBCUDA_PATH=/run/opengl-driver/lib \
  MODEL_DIR=/home/tianyixia/models/Qwen3.8-27B-FP8 \
  PROFILE_FILE="$PROFILE_FILE" \
  MODE=fast \
  PORT="${PORT:-8000}" \
  SERVICE_SCOPE=lan \
  GPU_DEVICES=0,1 \
  TP_SIZE=2 \
  VLLM_ALLOW_MAMBA_SPEC_FULL_CUDAGRAPH=0 \
  VLLM_SM75_SPEC_SYNC_MODE=auto \
  VLLM_COMPILE_PREWARM=0 \
  START_TIMEOUT=900 \
  ./launcher.sh --non-interactive
