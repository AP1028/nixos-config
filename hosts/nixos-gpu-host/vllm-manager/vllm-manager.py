#!/usr/bin/env python3
"""vLLM model manager + OpenAI-compatible API proxy for nixos-gpu-host.

One process, two HTTP listeners:

  * control panel + management API   (default 0.0.0.0:8500)
      GET  /                web UI
      GET  /api/status      backend state, VRAM, host memory
      GET  /api/models      model registry
      GET  /api/logs        backend log tail (?lines=N&model=ID)
      POST /api/start       {"model": "<id>"}
      POST /api/stop        stop the running model
      POST /api/switch      {"model": "<id>"}  (stop + start)
      GET  /health          manager liveness

  * OpenAI-compatible API proxy     (default 0.0.0.0:8000 -> 127.0.0.1:8001)
      Every path is streamed through to the vLLM backend (chat completions,
      completions, models, /docs, ...).  When no model is running the proxy
      answers 503 with a JSON error.

The vLLM backend runs with the same TP=2 / FP8 / MTP3 / PIECEWISE flags as the
existing direct-start launcher, but binds 127.0.0.1:8001 (internal only); the
public OpenAI endpoint stays on port 8000.

Stdlib only (no pip dependencies).  Config comes from models.json; persistent
state and per-model logs live in the working directory (systemd
StateDirectory=/var/lib/vllm-manager).
"""

from __future__ import annotations

import http.client
import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# NixOS keeps ninja/gcc/cmake/nvidia-smi/ss/pkill in /run/current-system/sw/bin,
# but systemd services start with a minimal PATH.  Fix PATH once at import so
# both the manager's own subprocess calls and the vLLM workers it spawns can
# find the toolchain (JIT builds C++ extensions and needs ninja/gcc).
_NIX_SW_BIN = "/run/current-system/sw/bin"
if os.path.isdir(_NIX_SW_BIN) and _NIX_SW_BIN not in os.environ.get("PATH", ""):
    os.environ["PATH"] = _NIX_SW_BIN + ":" + os.environ.get("PATH", "/usr/bin:/bin")

APP_DIR = Path(os.environ.get("VLLM_MANAGER_APP_DIR", Path(__file__).resolve().parent))
STATE_DIR = Path(os.environ.get("VLLM_MANAGER_STATE_DIR", os.getcwd()))
CONFIG_PATH = Path(os.environ.get("VLLM_MANAGER_CONFIG", APP_DIR / "models.json"))
CA_CERT_PATH = os.environ.get("VLLM_MANAGER_CA_CERT", "")

STATE_PATH = STATE_DIR / "state.json"
LOG_DIR = STATE_DIR / "logs"
WEB_DIR = APP_DIR / "web"

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade",
}

# Context modes. 98k is the vision-compatible default (KV capacity with the
# vision encoder loaded is 99,016 tokens). 128k is text-only (measured KV
# capacity 144,606 tokens). "native" targets the model's configured
# max_position_embeddings (262,144) text-only with turboquant_k8v4 KV (the
# most compact fork-verified dtype, 19.8 GiB at 98k in the tuning runs).
# Measured 4bit_nc KV capacity is 377,487 tokens (1.44x of 262,144), so
# native serves the model's full configured 256k window.
MAX_MODEL_LEN = 98304
CONTEXT_MODES = {
    "98k": {"max_model_len": 98304, "text_only": False, "kv_cache_dtype": None, "eager": False, "gpu_util": 0.94},
    # fp16 KV fits at most 116,000 tokens on the uncensored checkpoint
    # (fork: "estimated maximum model length is 116000"); fp16 avoids the
    # turboquant workspace-lock crash on long chunked prefill.
    "116k": {"max_model_len": 116000, "text_only": True, "kv_cache_dtype": None, "eager": False, "gpu_util": 0.94},
    # 200k: 4-bit KV, eager (no CUDA graphs - the turboquant continuation
    # workspace overflows the post-capture lock) at gpu_util 0.92 so eager's
    # dynamic prefill buffers have ~450 MiB/GPU of working headroom.
    # 200k FAST recipe: int8-per-token-head KV doubles the fp16 capacity
    # (~232k tokens) while keeping PIECEWISE graphs + MTP3 + prefix caching,
    # so decode stays near the 58 tok/s of the small tiers.
    "200k": {"max_model_len": 200000, "text_only": True, "kv_cache_dtype": "int8_per_token_head", "eager": False, "gpu_util": 0.94, "prefix_cache": True, "mtp": True, "thinking_budget": 16384},
    # Native 256k: same eager + 4-bit KV recipe at 0.90 util for working
    # headroom, with the unlimited-thinking effort capped to a 16k default
    # budget so reasoning cannot balloon activations into an OOM.
    "native": {"max_model_len": 262144, "text_only": True, "kv_cache_dtype": "turboquant_4bit_nc", "eager": True, "gpu_util": 0.88, "thinking_budget": 16384, "prefix_cache": False, "mtp": False},
}
DEFAULT_CONTEXT_MODE = "98k"
GPU_UTIL = 0.94

# Thinking-effort tiers. "off" disables thinking at the template; low/medium/
# high set VLLM_DEFAULT_THINKING_TOKEN_BUDGET (the fork applies it when a
# request carries no thinking_token_budget of its own); "max" leaves the
# template default (unlimited thinking).
EFFORTS = ["off", "low", "medium", "high", "max"]
EFFORT_BUDGETS = {"low": 1024, "medium": 4096, "high": 16384}


class Config:
    def __init__(self, raw: dict):
        self.raw = raw
        self.control_host = str(raw.get("control_host", "0.0.0.0"))
        self.control_port = int(raw.get("control_port", 8500))
        self.api_host = str(raw.get("api_host", "0.0.0.0"))
        self.api_port = int(raw.get("api_port", 8000))
        self.backend_host = str(raw.get("backend_host", "127.0.0.1"))
        self.backend_port = int(raw.get("backend_port", 9001))
        self.public_scheme = str(raw.get("public_scheme", "https"))
        self.public_control_port = int(raw.get("public_control_port", 8000))
        self.public_api_port = int(raw.get("public_api_port", 8001))
        self.runtime_root = Path(raw["runtime_root"]).expanduser()
        self.default_model = str(raw.get("default_model", ""))
        self.start_timeout_s = int(raw.get("start_timeout_s", 420))
        self.models = raw.get("models", [])

    def model(self, model_id: str) -> dict:
        for m in self.models:
            if m["id"] == model_id:
                return m
        raise KeyError(f"unknown model id: {model_id}")


def load_config() -> Config:
    with CONFIG_PATH.open("r", encoding="utf-8") as fh:
        return Config(json.load(fh))


CFG = load_config()
OP_LOCK = threading.RLock()
STARTED_AT = time.time()


# ---------------------------------------------------------------- state

def load_state() -> dict:
    try:
        with STATE_PATH.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return new_state()


def new_state() -> dict:
    return {
        "current_model": None,
        "pid": None,
        "phase": "stopped",        # stopped | starting | ready | failed
        "port": CFG.backend_port,
        "log": None,
        "started_at": None,
        "healthy": False,
        "failure": None,
        "manual_stop": False,
        "vision": None,
        "thinking_effort": None,
        "context_mode": None,
        "max_model_len": None,
        "last_logs": {},
        "vision_modes": {},
        "thinking_efforts": {},
        "context_modes": {},
    }


def save_state(st: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=2), encoding="utf-8")
    os.replace(tmp, STATE_PATH)


def pid_alive(pid) -> bool:
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def backend_health_ok() -> bool:
    try:
        with urllib.request.urlopen(
            f"http://{CFG.backend_host}:{CFG.backend_port}/health", timeout=2.0
        ) as resp:
            return resp.status == 200
    except Exception:
        return False


def port_listening(port: int) -> bool:
    try:
        out = subprocess.run(
            ["ss", "-tln"], capture_output=True, text=True, timeout=5
        ).stdout
    except Exception:
        return False
    return any(f":{port} " in line for line in out.splitlines())


def gpu_query() -> tuple[list[dict], str | None]:
    """Return (gpus, error).  gpus: [{index,name,total_mib,used_mib,free_mib,util_pct}]"""
    try:
        out = subprocess.run(
            [
                "nvidia-smi", "--query-gpu=index,name,memory.total,memory.used,"
                "memory.free,utilization.gpu", "--format=csv,noheader,nounits",
            ],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode != 0:
            return [], (out.stderr or "nvidia-smi failed").strip()[:300]
        gpus = []
        for line in out.stdout.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 6:
                continue
            gpus.append({
                "index": int(parts[0]),
                "name": parts[1],
                "total_mib": int(float(parts[2])),
                "used_mib": int(float(parts[3])),
                "free_mib": int(float(parts[4])),
                "util_pct": int(float(parts[5])),
            })
        return gpus, None
    except FileNotFoundError:
        return [], "nvidia-smi not found"
    except Exception as exc:  # noqa: BLE001
        return [], str(exc)[:300]


def gpus_free() -> tuple[bool, str]:
    """True when both GPUs have negligible VRAM usage (no other server)."""
    gpus, err = gpu_query()
    if err:
        return True, err  # cannot check; don't block
    busy = [g for g in gpus if g["used_mib"] > 2048]
    if busy:
        detail = ", ".join(f"GPU{g['index']} {g['used_mib']}MiB" for g in busy)
        return False, f"GPUs still busy: {detail}"
    return True, ""


def host_memory() -> dict:
    info = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, _, rest = line.partition(":")
            key = key.strip()
            if key in ("MemTotal", "MemAvailable"):
                info[key.lower()] = int(rest.split()[0]) // 1024
    except OSError:
        pass
    return info


def tail_of(path, lines: int = 200) -> str:
    if not path or not Path(path).is_file():
        return ""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            chunk = max(4096, min(size, 256 * 1024))
            fh.seek(max(0, size - chunk))
            data = fh.read().decode("utf-8", errors="replace")
        return "\n".join(data.splitlines()[-lines:])
    except OSError:
        return ""


# ------------------------------------------------------- vLLM backend

def backend_python() -> Path:
    return CFG.runtime_root / ".venv" / "bin" / "python"


def build_env(model: dict, effort: str = "max", context_mode: str = DEFAULT_CONTEXT_MODE) -> dict:
    root = str(CFG.runtime_root)
    fl = f"{root}/.deps/FlashQLA-SM70-SM75"
    env = os.environ.copy()
    venv_bin = str(CFG.runtime_root / ".venv" / "bin")
    if venv_bin not in env.get("PATH", ""):
        env["PATH"] = f"{venv_bin}:" + env.get("PATH", "/usr/bin:/bin")
    env.update({
        "CUDA_HOME": "/etc/vllm-cuda-home",
        "CUDA_PATH": "/etc/vllm-cuda-home",
        "CUDACXX": "/etc/vllm-cuda-home/bin/nvcc",
        "LD_LIBRARY_PATH": "/run/opengl-driver/lib:/etc/vllm-cuda-home/lib",
        "TRITON_LIBCUDA_PATH": "/run/opengl-driver/lib",
        "CUDA_VISIBLE_DEVICES": "0,1",
        "CUDA_DEVICE_ORDER": "PCI_BUS_ID",
        "TORCH_CUDA_ARCH_LIST": "7.5",
        "FLASHQLA_ROOT": fl,
        "PYTHONPATH": f"{root}:{fl}",
        "TORCH_EXTENSIONS_DIR": f"{fl}/.torch_extensions_vllm_flashqla_legacy",
        "FLASHINFER_ENABLE_AOT": "1",
        "TORCHINDUCTOR_CACHE_DIR": f"{root}/torchinductor-cache",
        "TRITON_CACHE_DIR": f"{root}/triton-cache",
        "PYTHONUNBUFFERED": "1",
        "STABLE_ROOT": root,
        "VLLM_ALLOW_MAMBA_SPEC_FULL_CUDAGRAPH": "0",
        "VLLM_SM75_SPEC_SYNC_MODE": str(model.get("spec_sync_mode", "safe")),
        # Match the legacy launcher's tool-calling posture.
        "VLLM_ENFORCE_STRICT_TOOL_CALLING": "0",
    })
    if effort in EFFORT_BUDGETS:
        env["VLLM_DEFAULT_THINKING_TOKEN_BUDGET"] = str(EFFORT_BUDGETS[effort])
    else:
        env.pop("VLLM_DEFAULT_THINKING_TOKEN_BUDGET", None)
        mode = CONTEXT_MODES.get(context_mode, CONTEXT_MODES[DEFAULT_CONTEXT_MODE])
        if mode.get("thinking_budget"):
            # "max" effort on a memory-tight tier: bound the default budget so
            # unbounded reasoning cannot OOM the eager execution.
            env["VLLM_DEFAULT_THINKING_TOKEN_BUDGET"] = str(mode["thinking_budget"])
    return env


def build_args(model: dict, vision: bool = False, effort: str = "max",
               context_mode: str = DEFAULT_CONTEXT_MODE) -> list[str]:
    mode = CONTEXT_MODES.get(context_mode, CONTEXT_MODES[DEFAULT_CONTEXT_MODE])
    # 128k/native context modes force text-only: the vision encoder does not
    # fit alongside the larger KV pool.
    text_only = mode["text_only"] or not vision
    max_model_len = mode["max_model_len"]
    # The eager tiers need 4096-token chunks for the 4bit_nc block size;
    # graph tiers (fp16/int8 KV) keep the tuning-proven 2048.
    batched = 4096 if mode["eager"] else 2048
    args = [
        "--host", CFG.backend_host,
        "--port", str(CFG.backend_port),
        "--model", str(model["model_dir"]),
        "--served-model-name", str(model["served_name"]),
        "--dtype", "half",
        "--tensor-parallel-size", "2",
        "--generation-config", "vllm",
        "--max-model-len", str(max_model_len),
        "--enable-chunked-prefill",
        "--max-num-seqs", "1",
        "--max-num-batched-tokens", str(batched),
        "--quantization", "fp8",
        "--gpu-memory-utilization", f"{mode.get('gpu_util', GPU_UTIL):.3f}",
        "--enable-prompt-tokens-details",
    ]
    if mode["kv_cache_dtype"]:
        args += ["--kv-cache-dtype", mode["kv_cache_dtype"]]
    if mode["eager"]:
        # No CUDA graph capture: the turboquant continuation-prefill
        # workspace can grow freely instead of hitting the locked size.
        args += ["--enforce-eager"]
    if text_only:
        # Text-only serving: skip the vision encoder and its profiling.
        args += ["--language-model-only", "--skip-mm-profiling"]
    if effort == "off":
        # Server-side default: disable the Qwen3 thinking block. Requests can
        # still re-enable it with chat_template_kwargs / thinking_token_budget.
        args += ["--default-chat-template-kwargs", '{"enable_thinking": false}']
    # Tool calling for agent clients (DSH sends tools with tool_choice=auto).
    # The Qwen3 template emits its native tool-call format; qwen3xml parses it
    # back into OpenAI tool_calls. Requests without tools are unaffected.
    args += ["--tool-call-parser", "qwen3_xml", "--enable-auto-tool-choice"]
    args += [
        "--disable-log-stats",
        "--reasoning-parser", "qwen3",
        "--additional-config", '{"gdn_prefill_backend":"flashqla_legacy"}',
    ]
    if mode.get("prefix_cache", True):
        # Prefix caching + mamba align retain per-length state buffers for the
        # longest sequence seen; on the eager compressed-KV tiers that grew
        # +2 GiB over seven requests and caused the recurrent OOMs, so those
        # tiers run without it.
        args += ["--mamba-cache-mode", "align", "--enable-prefix-caching"]
    if mode.get("mtp", True):
        args += ["--speculative-config", '{"method":"mtp","num_speculative_tokens":3}']
    args += [
        "--compilation-config",
        '{"cudagraph_mode":"PIECEWISE","cudagraph_capture_sizes":[4],'
        '"max_cudagraph_capture_size":4}',
    ]
    return args


def vision_preference(st: dict, model: dict) -> bool:
    """Per-model vision preference: runtime state override, else models.json."""
    modes = st.get("vision_modes", {})
    if model["id"] in modes:
        return bool(modes[model["id"]])
    return bool(model.get("vision", False))


def thinking_effort_preference(st: dict, model: dict) -> str:
    """Per-model thinking effort: runtime state override, else models.json."""
    modes = st.get("thinking_efforts", {})
    if model["id"] in modes:
        return modes[model["id"]]
    return str(model.get("thinking_effort", "max"))


def context_mode_preference(st: dict, model: dict) -> str:
    """Per-model context mode: runtime state override, else models.json."""
    modes = st.get("context_modes", {})
    if model["id"] in modes:
        return modes[model["id"]]
    return str(model.get("context", DEFAULT_CONTEXT_MODE))


class ManagerError(Exception):
    def __init__(self, message: str, status: int = 409):
        super().__init__(message)
        self.status = status


def start_model(model_id: str) -> dict:
    with OP_LOCK:
        try:
            model = CFG.model(model_id)
        except KeyError as exc:
            raise ManagerError(f"unknown model id: {model_id}", 400) from exc
        st = load_state()

        if st.get("current_model") and st.get("phase") in ("starting", "ready"):
            if pid_alive(st.get("pid")) or backend_health_ok():
                raise ManagerError(
                    f"model '{st['current_model']}' is already running; "
                    "stop it first (or use /api/switch)"
                )

        if port_listening(CFG.backend_port):
            raise ManagerError(
                f"backend port {CFG.backend_port} is busy; "
                "stop the running backend first"
            )

        ok, why = gpus_free()
        if not ok:
            raise ManagerError(f"cannot start: {why}")

        py = backend_python()
        if not py.is_file():
            raise ManagerError(f"backend python missing: {py}", 500)
        if not Path(str(model["model_dir"])).is_dir():
            raise ManagerError(f"model dir missing: {model['model_dir']}", 500)

        LOG_DIR.mkdir(parents=True, exist_ok=True)
        log_path = LOG_DIR / f"{model_id}-{time.strftime('%Y%m%d-%H%M%S')}.log"
        logf = open(log_path, "ab")  # noqa: SIM115 (kept open for the child)

        vision = vision_preference(st, model)
        effort = thinking_effort_preference(st, model)
        context_mode = context_mode_preference(st, model)
        mode = CONTEXT_MODES.get(context_mode, CONTEXT_MODES[DEFAULT_CONTEXT_MODE])
        args = build_args(model, vision, effort, context_mode)
        env = build_env(model, effort, context_mode)
        # NOTE: expandable_segments was tried and made the recurrent OOMs
        # worse - eager-mode requests of varying shapes kept growing the
        # reserved segments until the GPU was exhausted.  The default
        # caching allocator frees unused blocks instead.
        env.pop("PYTORCH_CUDA_ALLOC_CONF", None)
        try:
            proc = subprocess.Popen(
                [str(py), "-m", "vllm.entrypoints.openai.api_server", *args],
                cwd=str(CFG.runtime_root),
                env=env,
                stdout=logf,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as exc:
            logf.close()
            raise ManagerError(f"failed to spawn vLLM: {exc}", 500) from exc

        st.update({
            "current_model": model_id,
            "pid": proc.pid,
            "phase": "starting",
            "port": CFG.backend_port,
            "log": str(log_path),
            "started_at": time.time(),
            "healthy": False,
            "failure": None,
            "manual_stop": False,
            "vision": vision and not mode["text_only"],
            "thinking_effort": effort,
            "context_mode": context_mode,
            "max_model_len": mode["max_model_len"],
        })
        st.setdefault("last_logs", {})[model_id] = str(log_path)
        save_state(st)
        return {
            "ok": True,
            "model": model_id,
            "pid": proc.pid,
            "phase": "starting",
            "vision": vision and not mode["text_only"],
            "thinking_effort": effort,
            "context_mode": context_mode,
            "max_model_len": mode["max_model_len"],
            "log": str(log_path),
            "note": "backend is loading (CUDA graph capture); /health turns 200 "
                    "when ready (usually 1.5-3 min)",
        }


def _kill_process_group(pid: int, sig: int) -> None:
    try:
        os.killpg(int(pid), sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        try:
            os.kill(int(pid), sig)
        except (ProcessLookupError, PermissionError):
            pass
    except OSError:
        try:
            os.kill(int(pid), sig)
        except (ProcessLookupError, PermissionError):
            pass


def stop_model() -> dict:
    with OP_LOCK:
        st = load_state()
        pid = st.get("pid")
        stopped_pid = bool(pid and pid_alive(pid))

        if pid:
            _kill_process_group(int(pid), signal.SIGTERM)

        # graceful window
        for _ in range(30):
            if not pid_alive(pid):
                break
            time.sleep(0.5)
        if pid_alive(pid):
            _kill_process_group(int(pid), signal.SIGKILL)
            time.sleep(1)

        # belt & braces: pattern kill anything left on the internal port
        pattern = (f"vllm.entrypoints.openai.api_server --host {CFG.backend_host} "
                   f"--port {CFG.backend_port}")
        subprocess.run(["pkill", "-TERM", "-f", pattern], capture_output=True)
        time.sleep(3)
        subprocess.run(["pkill", "-KILL", "-f", pattern], capture_output=True)
        subprocess.run(["pkill", "-KILL", "-f", "VLLM::"], capture_output=True)

        # wait for the port and the GPUs to actually free up
        for _ in range(30):
            if not port_listening(CFG.backend_port) and gpus_free()[0]:
                break
            time.sleep(1)

        if st.get("current_model") and st.get("log"):
            st.setdefault("last_logs", {})[st["current_model"]] = st["log"]

        st.update({
            "current_model": None,
            "pid": None,
            "phase": "stopped",
            "log": None,
            "started_at": None,
            "healthy": False,
            "failure": None,
            "manual_stop": True,
            "vision": None,
            "thinking_effort": None,
            "context_mode": None,
            "max_model_len": None,
        })
        save_state(st)
        return {"ok": True, "stopped": stopped_pid, "phase": "stopped"}


def switch_model(model_id: str) -> dict:
    with OP_LOCK:
        stop_result = stop_model()
        start_result = start_model(model_id)
        return {"ok": True, "stopped": stop_result, "started": start_result}


def set_thinking_effort(model_id: str, effort: str) -> dict:
    """Persist the per-model thinking-effort preference; restart the backend
    when the running model's effort changes so the flag takes effect now."""
    if effort not in EFFORTS:
        raise ManagerError(f"unknown effort: {effort} (use off/low/medium/high/max)", 400)
    with OP_LOCK:
        try:
            CFG.model(model_id)
        except KeyError as exc:
            raise ManagerError(f"unknown model id: {model_id}", 400) from exc
        st = load_state()
        st.setdefault("thinking_efforts", {})[model_id] = effort
        save_state(st)
        restarted = None
        if st.get("current_model") == model_id and st.get("phase") in ("starting", "ready"):
            stop_model()
            restarted = start_model(model_id)
        return {
            "ok": True,
            "model": model_id,
            "effort": effort,
            "restarted": restarted is not None,
            "note": ("backend restarted with the new effort; load takes 1.5-3 min"
                     if restarted is not None else
                     "preference saved; applies the next time this model starts"),
        }


def set_context(model_id: str, mode: str) -> dict:
    """Persist the per-model context mode; restart the backend when the
    running model's mode changes so the new window takes effect now."""
    if mode not in CONTEXT_MODES:
        raise ManagerError(f"unknown context mode: {mode} (use 98k/128k/native)", 400)
    with OP_LOCK:
        try:
            CFG.model(model_id)
        except KeyError as exc:
            raise ManagerError(f"unknown model id: {model_id}", 400) from exc
        st = load_state()
        st.setdefault("context_modes", {})[model_id] = mode
        save_state(st)
        restarted = None
        if st.get("current_model") == model_id and st.get("phase") in ("starting", "ready"):
            stop_model()
            restarted = start_model(model_id)
        return {
            "ok": True,
            "model": model_id,
            "mode": mode,
            "restarted": restarted is not None,
            "note": ("backend restarted with the new context mode; load takes 1.5-3 min"
                     if restarted is not None else
                     "preference saved; applies the next time this model starts"),
        }


def set_vision(model_id: str, enabled: bool) -> dict:
    """Persist the per-model vision preference; restart the backend when the
    running model's mode changes so the flag takes effect immediately."""
    with OP_LOCK:
        try:
            CFG.model(model_id)
        except KeyError as exc:
            raise ManagerError(f"unknown model id: {model_id}", 400) from exc
        st = load_state()
        st.setdefault("vision_modes", {})[model_id] = bool(enabled)
        save_state(st)
        restarted = None
        if st.get("current_model") == model_id and st.get("phase") in ("starting", "ready"):
            stop_model()
            restarted = start_model(model_id)
        return {
            "ok": True,
            "model": model_id,
            "vision": bool(enabled),
            "restarted": restarted is not None,
            "note": ("backend restarted with the new mode; load takes 1.5-3 min"
                     if restarted is not None else
                     "preference saved; applies the next time this model starts"),
        }


# ---------------------------------------------------------- status

def build_status() -> dict:
    with OP_LOCK:
        st = load_state()
    current = st.get("current_model")
    model_info = None
    if current:
        try:
            m = CFG.model(current)
            model_info = {"id": m["id"], "served_name": m["served_name"],
                          "display_name": m.get("display_name", m["id"])}
        except KeyError:
            model_info = {"id": current}

    gpus, gpu_err = gpu_query()
    hostname = socket.gethostname()
    models = []
    for m in CFG.models:
        entry = {
            "id": m["id"],
            "display_name": m.get("display_name", m["id"]),
            "served_name": m["served_name"],
            "model_dir": m["model_dir"],
            "note": m.get("note", ""),
            "state": "stopped",
            "vision": vision_preference(st, m),
            "thinking_effort": thinking_effort_preference(st, m),
            "context_mode": context_mode_preference(st, m),
        }
        if current == m["id"]:
            entry["state"] = st.get("phase", "stopped")
        models.append(entry)

    uptime = 0
    if st.get("started_at"):
        uptime = int(time.time() - st["started_at"])

    return {
        "host": hostname,
        "time": time.time(),
        "manager": {
            "pid": os.getpid(),
            "uptime_s": int(time.time() - STARTED_AT),
            "scheme": CFG.public_scheme,
            "control_port": CFG.public_control_port,
            "api_port": CFG.public_api_port,
            "backend_port": CFG.backend_port,
            "control_url": f"{CFG.public_scheme}://{hostname}:{CFG.public_control_port}/",
            "api_url": f"{CFG.public_scheme}://{hostname}:{CFG.public_api_port}/v1",
        },
        "backend": {
            "model": model_info,
            "phase": st.get("phase", "stopped"),
            "healthy": st.get("healthy", False) and backend_health_ok(),
            "pid": st.get("pid"),
            "port": st.get("port", CFG.backend_port),
            "started_at": st.get("started_at"),
            "uptime_s": uptime,
            "failure": st.get("failure"),
            "vision": st.get("vision"),
            "thinking_effort": st.get("thinking_effort"),
            "context_mode": st.get("context_mode"),
            "max_model_len": st.get("max_model_len"),
            "log": st.get("log"),
        },
        "models": models,
        "gpus": gpus,
        "gpus_error": gpu_err,
        "host_memory": host_memory(),
        "manual_stop": st.get("manual_stop", True),
        "default_model": CFG.default_model,
    }


def log_tail(model_id: str | None, lines: int) -> str:
    with OP_LOCK:
        st = load_state()
    if model_id and model_id != st.get("current_model"):
        path = st.get("last_logs", {}).get(model_id)
    else:
        path = st.get("log")
    return tail_of(path, lines)


# ------------------------------------------------------------ monitor

def monitor_loop() -> None:
    """Track backend phase: starting -> ready, -> failed on crash, and
    auto-restart a ready backend whose engine died (EngineDeadError-style
    crashes leave the API process alive but every request 500s)."""
    unhealthy_ticks = 0
    while True:
        time.sleep(3)
        try:
            with OP_LOCK:
                st = load_state()
                phase = st.get("phase")
                if phase not in ("starting", "ready"):
                    unhealthy_ticks = 0
                    continue
                pid = st.get("pid")
                if backend_health_ok():
                    unhealthy_ticks = 0
                    if phase != "ready":
                        st["phase"] = "ready"
                        st["healthy"] = True
                        st["failure"] = None
                        save_state(st)
                elif phase == "ready":
                    # lost health while the API process is alive: the engine
                    # core has died.  Give it a few ticks, then self-heal.
                    unhealthy_ticks += 1
                    st["healthy"] = False
                    save_state(st)
                    if unhealthy_ticks >= 4:
                        model_id = st.get("current_model")
                        print(f"monitor: engine dead for {model_id}; "
                              "auto-restarting the backend", file=sys.stderr)
                        st["failure"] = ("engine died; auto-restarted by the manager at "
                                         + time.strftime("%F %T"))[-2000:]
                        save_state(st)
                        stop_model()
                        if model_id:
                            try:
                                start_model(model_id)
                            except ManagerError as exc:
                                print(f"monitor: auto-restart failed: {exc}",
                                      file=sys.stderr)
                        unhealthy_ticks = 0
                elif not pid_alive(pid):
                    unhealthy_ticks = 0
                    st["phase"] = "failed"
                    st["healthy"] = False
                    st["failure"] = (tail_of(st.get("log"), 25) or "backend exited")[-2000:]
                    save_state(st)
        except Exception as exc:  # noqa: BLE001
            print(f"monitor error: {exc}", file=sys.stderr)


def bootstrap() -> None:
    """On manager start: adopt a surviving backend, otherwise auto-start the
    default model (unless the user explicitly stopped everything)."""
    with OP_LOCK:
        st = load_state()
        if st.get("current_model") and st.get("phase") in ("starting", "ready"):
            if backend_health_ok() or pid_alive(st.get("pid")):
                if backend_health_ok():
                    st["phase"] = "ready"
                    st["healthy"] = True
                    if st.get("vision") is None:
                        # Pre-vision-toggle state: an adopted backend was
                        # launched text-only under the old manager.
                        st["vision"] = False
                    if st.get("thinking_effort") is None:
                        # Pre-effort-toggle state: no budget default was set.
                        st["thinking_effort"] = "max"
                    if st.get("context_mode") is None:
                        # Pre-context-toggle state: the 98k default was served.
                        st["context_mode"] = DEFAULT_CONTEXT_MODE
                        st["max_model_len"] = CONTEXT_MODES[DEFAULT_CONTEXT_MODE]["max_model_len"]
                    save_state(st)
                return  # adopt the running backend

        # stale or empty state
        st["current_model"] = None
        st["pid"] = None
        st["phase"] = "stopped"
        st["healthy"] = False
        st["failure"] = None
        save_state(st)

        if st.get("manual_stop"):
            return
        if not CFG.default_model:
            return
    try:
        result = start_model(CFG.default_model)
        print(f"auto-started default model: {result['model']}", file=sys.stderr)
    except ManagerError as exc:
        print(f"auto-start failed: {exc}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        print(f"auto-start failed: {exc}", file=sys.stderr)


# ------------------------------------------------------- HTTP servers

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
}


def _cors_headers(handler) -> None:
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "*")


def _read_json_body(handler) -> dict:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        length = 0
    if length <= 0 or length > 1_048_576:
        return {}
    try:
        return json.loads(handler.rfile.read(length).decode("utf-8") or "{}")
    except json.JSONDecodeError as exc:
        raise ManagerError(f"invalid JSON body: {exc}", 400) from exc


class ControlHandler(http.server.BaseHTTPRequestHandler):
    server_version = "VllmManagerControl/1.0"

    def log_message(self, fmt, *args):  # noqa: A003
        print(f"[control] {self.address_string()} {fmt % args}", file=sys.stderr)

    def _send_json(self, obj, status: int = 200) -> None:
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        _cors_headers(self)
        self.end_headers()
        self.wfile.write(payload)

    def _send_error_json(self, message: str, status: int = 409) -> None:
        self._send_json({"ok": False, "error": message}, status)

    def _serve_static(self, name: str) -> None:
        path = (WEB_DIR / name).resolve()
        if WEB_DIR.resolve() not in path.parents and path != WEB_DIR.resolve():
            self._send_error_json("not found", 404)
            return
        if not path.is_file():
            self._send_error_json("not found", 404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(path.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                self._serve_static("index.html")
            elif path == "/style.css":
                self._serve_static("style.css")
            elif path == "/app.js":
                self._serve_static("app.js")
            elif path == "/health":
                self._send_json({"status": "ok", "service": "vllm-manager"})
            elif path == "/ca.crt":
                if CA_CERT_PATH and Path(CA_CERT_PATH).is_file():
                    data = Path(CA_CERT_PATH).read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-pem-file")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    self._send_error_json("CA certificate not configured", 404)
            elif path == "/api/status":
                self._send_json(build_status())
            elif path == "/api/models":
                self._send_json({"models": CFG.models, "default_model": CFG.default_model})
            elif path == "/api/logs":
                lines = int((query.get("lines") or ["200"])[0])
                model_id = (query.get("model") or [None])[0]
                self._send_json({"lines": lines, "model": model_id,
                                 "log": log_tail(model_id, min(lines, 2000))})
            else:
                self._send_error_json(f"not found: {path}", 404)
        except (ManagerError, ValueError) as exc:
            status = exc.status if isinstance(exc, ManagerError) else 400
            self._send_error_json(str(exc), status)
        except Exception as exc:  # noqa: BLE001
            self._send_error_json(str(exc), 500)

    def do_POST(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        try:
            body = _read_json_body(self)
            if path == "/api/start":
                model_id = body.get("model") or CFG.default_model
                self._send_json(start_model(model_id), 202)
            elif path == "/api/stop":
                self._send_json(stop_model())
            elif path == "/api/switch":
                model_id = body.get("model")
                if not model_id:
                    raise ManagerError("missing 'model' in JSON body", 400)
                self._send_json(switch_model(model_id), 202)
            elif path == "/api/vision":
                model_id = body.get("model")
                if not model_id:
                    raise ManagerError("missing 'model' in JSON body", 400)
                self._send_json(set_vision(model_id, bool(body.get("enabled", False))), 202)
            elif path == "/api/thinking":
                model_id = body.get("model")
                if not model_id:
                    raise ManagerError("missing 'model' in JSON body", 400)
                self._send_json(set_thinking_effort(model_id, str(body.get("effort", "max"))), 202)
            elif path == "/api/context":
                model_id = body.get("model")
                if not model_id:
                    raise ManagerError("missing 'model' in JSON body", 400)
                self._send_json(set_context(model_id, str(body.get("mode", DEFAULT_CONTEXT_MODE))), 202)
            else:
                self._send_error_json(f"not found: {path}", 404)
        except ManagerError as exc:
            self._send_error_json(str(exc), exc.status)
        except Exception as exc:  # noqa: BLE001
            self._send_error_json(str(exc), 500)

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        _cors_headers(self)
        self.send_header("Content-Length", "0")
        self.end_headers()


def normalize_chat_messages(body: bytes | None, path: str) -> bytes | None:
    """Move/merge system messages to the front of chat-completion requests.

    The Qwen3 chat template raises "System message must be at the beginning"
    when any system message appears after the first position (SillyTavern
    injects persona/world-info system blocks mid-history).  Server-side
    normalization keeps every OpenAI-compatible client working: string system
    contents are merged into one leading system message, non-string system
    blocks are moved verbatim right behind it.
    """
    if body is None:
        return None
    if "/chat/completions" not in path:
        return body
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return body
    msgs = data.get("messages")
    if not isinstance(msgs, list) or len(msgs) < 2:
        return body
    systems = [m for m in msgs if isinstance(m, dict) and m.get("role") == "system"]
    if not systems:
        return body
    if msgs[0] is systems[0] and all(m.get("role") != "system" for m in msgs[1:]):
        return body  # already a single leading system message
    text_parts: list[str] = []
    verbatim: list[dict] = []
    for m in systems:
        content = m.get("content")
        if isinstance(content, str) and content.strip():
            text_parts.append(content.strip())
        else:
            verbatim.append(m)
    leading: list[dict] = []
    if text_parts:
        leading.append({"role": "system", "content": "\n\n".join(text_parts)})
    leading.extend(verbatim)
    rest = [m for m in msgs if not (isinstance(m, dict) and m.get("role") == "system")]
    data["messages"] = leading + rest
    return json.dumps(data, ensure_ascii=False).encode("utf-8")


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "VllmManagerProxy/1.0"

    def log_message(self, fmt, *args):  # noqa: A003
        print(f"[proxy] {self.address_string()} {fmt % args}", file=sys.stderr)

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        _cors_headers(self)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _relay(self) -> None:
        backend_host = CFG.backend_host
        backend_port = CFG.backend_port

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else None
        if CFG.raw.get("normalize_system_messages", True):
            body = normalize_chat_messages(body, self.path)

        fwd = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP:
                continue
            fwd[key] = value
        fwd["Host"] = f"{backend_host}:{backend_port}"
        # The normalization above can change the body length; always restate
        # Content-Length from the bytes actually forwarded.
        if body is not None:
            fwd["Content-Length"] = str(len(body))

        conn = None
        try:
            conn = http.client.HTTPConnection(backend_host, backend_port, timeout=600)
            conn.request(self.command, self.path, body=body, headers=fwd)
            resp = conn.getresponse()
        except (ConnectionRefusedError, OSError, http.client.HTTPException) as exc:
            if conn is not None:
                try:
                    conn.close()
                except Exception:  # noqa: BLE001
                    pass
            payload = json.dumps({
                "error": {
                    "message": ("vLLM backend is not running. Start a model "
                                "from the control panel."),
                    "type": "backend_down",
                },
                "detail": str(exc),
            }).encode("utf-8")
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            _cors_headers(self)
            self.end_headers()
            self.wfile.write(payload)
            return

        try:
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            _cors_headers(self)
            self.end_headers()
            self.close_connection = True
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _relay  # noqa: N815


def serve(host: str, port: int, handler) -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


# ------------------------------------------------------------------ main

def main() -> None:
    threading.Thread(target=monitor_loop, name="monitor", daemon=True).start()
    bootstrap()

    control = serve(CFG.control_host, CFG.control_port, ControlHandler)
    proxy = serve(CFG.api_host, CFG.api_port, ProxyHandler)

    print(f"vllm-manager: control http://{CFG.control_host}:{CFG.control_port} "
          f"(UI + mgmt API)", file=sys.stderr)
    print(f"vllm-manager: api proxy http://{CFG.api_host}:{CFG.api_port} -> "
          f"http://{CFG.backend_host}:{CFG.backend_port}", file=sys.stderr)
    print(f"vllm-manager: state {STATE_PATH} logs {LOG_DIR}", file=sys.stderr)

    threading.Thread(target=control.serve_forever, name="control", daemon=True).start()
    try:
        proxy.serve_forever()
    finally:
        control.shutdown()
        proxy.server_close()


if __name__ == "__main__":
    main()
