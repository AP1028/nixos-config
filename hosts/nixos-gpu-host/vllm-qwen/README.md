# vLLM Qwen3.8-27B-FP8 on gpu-host (2x RTX 2080 Ti 22GB)

This directory holds the operational notes, launcher wrappers, tuned profile,
and benchmark tooling for serving **Qwen/Qwen3.8-27B-FP8** on `nixos-gpu-host`
with the
[weicj/vLLM-2080Ti-Definitive](https://github.com/weicj/vLLM-2080Ti-Definitive)
fork (branch `vllm-2080ti-deifinitive`, fork release v0.1.15).

- Runtime: vLLM 0.21.0 fork, torch 2.11.0+cu128, NVIDIA driver 595.71.05
- Hardware: 2x RTX 2080 Ti 22GB, NVLink NV2 (P2P OK), TP=2, sm_75
- Model dir: `/home/tianyixia/models/Qwen3.8-27B-FP8` (full FP8 repo, 81 files,
  ~28.77 GiB, including `mtp.safetensors` and `outside.safetensors`)

> The previous llama.cpp DeepSeek service (`llama-server`) stays stopped and is
> not touched. Do not delete
> `/home/tianyixia/DeepSeek-V4-Flash-0731-MXFP4-*.gguf`.

## Checkout / build on NixOS

The fork's `build.sh` expects a Debian/Ubuntu-style CUDA layout
(`$CUDA_HOME/targets/x86_64-linux/lib`). On gpu-host the Nix CUDA toolkit
(cuda-merged 12.9) uses a flat `lib/`, so a compatibility tree is used:

```sh
# switch gateway for international downloads first (root op, on the host):
#   sudo-env -c '/home/tianyixia/nixos-config/route-gateway.sh 192.168.3.2'

M=/nix/store/3lpf2hl979sfmyb9f573xq1bz3xkds0v-cuda-merged-12.9
mkdir -p ~/cuda-12.9/targets/x86_64-linux
ln -sfn "$M/bin"        ~/cuda-12.9/bin
ln -sfn "$M/include"    ~/cuda-12.9/include
ln -sfn "$M/lib"        ~/cuda-12.9/lib
ln -sfn "$M/lib"        ~/cuda-12.9/lib64
ln -sfn "$M/lib"        ~/cuda-12.9/targets/x86_64-linux/lib
ln -sfn "$M/nvvm"       ~/cuda-12.9/nvvm

git clone --depth 1 --branch vllm-2080ti-deifinitive \
  https://github.com/weicj/vLLM-2080Ti-Definitive.git ~/vLLM-2080Ti-Definitive
cd ~/vLLM-2080Ti-Definitive

# GCC 15 (system) is too new for CUDA 12.9 nvcc; use the Nix gcc-14 wrapper.
G=/nix/store/kz3gj6nscr77c6k5jxpjdyj2f81c0g6h-gcc-wrapper-14.4.0
CUDA_HOME=$HOME/cuda-12.9 \
CC=$G/bin/gcc CXX=$G/bin/g++ CUDAHOSTCXX=$G/bin/g++ \
NVCC_PREPEND_FLAGS="-I$HOME/cuda-12.9/include" \
ASSUME_YES=1 MAX_JOBS=16 BUILD_MAX_JOBS=16 BUILD_AUTO_MAX_JOBS_CAP=16 \
BUILD_TORCH_PRIMARY_TIMEOUT_SECONDS=3600 \
BUILD_PYPI_PRIMARY_TIMEOUT_SECONDS=1800 \
BUILD_GIT_PRIMARY_TIMEOUT_SECONDS=900 \
./build.sh
```

NixOS-specific lesson: the PyTorch wheel index is slow for the 658 MB cudnn
wheel and `build.sh`'s default 90 s torch timeout is too short. Pre-installing
the exact torch stack makes the build resume safely:

```sh
# inside ~/vLLM-2080Ti-Definitive, after `build.sh` created .venv once:
.venv/bin/python -m pip install --no-deps \
  --index-url https://download.pytorch.org/whl/cu128 \
  torch==2.11.0+cu128 torchaudio==2.11.0+cu128 torchvision==0.26.0+cu128
.venv/bin/python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple \
  'cuda-toolkit[cublas,cudart,cufft,cufile,cupti,curand,cusolver,cusparse,nvjitlink,nvrtc,nvtx]==12.8.1' \
  'cuda-bindings<13,>=12.9.4' nvidia-cudnn-cu12==9.19.0.56 \
  nvidia-cusparselt-cu12==0.7.1 nvidia-nccl-cu12==2.28.9 nvidia-nvshmem-cu12==3.4.5 \
  filelock fsspec jinja2 'networkx>=2.5.1' 'sympy>=1.13.3' \
  'typing-extensions>=4.10.0' triton==3.6.0
```

## Start / stop

Use the wrappers (from this directory):

```sh
./run-vllm-qwen.sh fast      # fastest tuned profile (see tune section)
./run-vllm-qwen.sh normal    # shipped normal fp16kv-128K profile
./stop-vllm-qwen.sh
```

Or directly:

```sh
cd ~/vLLM-2080Ti-Definitive
MODEL_DIR=/home/tianyixia/models/Qwen3.8-27B-FP8 \
PROFILE=qwen27b/normal/fp8/fp16kv-128K-mtp3-text-only.env \
MODE=normal PORT=8000 SERVICE_SCOPE=lan GPU_DEVICES=0,1 TP_SIZE=2 \
CUDA_HOME=$HOME/cuda-12.9 \
LD_LIBRARY_PATH=/run/opengl-driver/lib \
CC=$G/bin/gcc CXX=$G/bin/g++ CUDAHOSTCXX=$G/bin/g++ \
./launcher.sh --non-interactive
```

`./launcher.sh --stop`-equivalent: run `./launcher.sh --non-interactive` with
the same `PORT`/`SERVICE_SCOPE` and `--set` stop? The wrapper uses the
launcher's saved state file:
`run-logs/start-manager.state` / `LAST_PID_FILE`.

## Benchmark

```sh
python3 bench_single_stream.py --url http://127.0.0.1:8000 --runs 3 --max-tokens 128
```

The script sends one warmup request, then N timed streaming `/v1/completions`
requests and reports TTFT, prefill tok/s, decode tok/s, per-GPU VRAM and host
RAM, and writes `bench_single_stream.json`.

## Measured results

See the tuning history and final table in
[../../docs/qwen3.8-27b-vllm-2080ti-report.md](../../docs/qwen3.8-27b-vllm-2080ti-report.md).
