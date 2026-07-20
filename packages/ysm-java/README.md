# ysm-java — Yes Steve Model native DRM bypass for NixOS

## Problem

YSM 2.6.5's `libysm-core.so` has two DRM checks in `JNI_OnLoad` that reject NixOS:

| Error | Cause | Triggered by |
|---|---|---|
| `err:54` | `java.vendor` check | nixpkgs JDKs patch `java.vendor` to `N/A` (or use bash wrappers) |
| `err:56` | Environment check | Time-dependent — fails at t=0, passes ~1s after JVM startup |

The `.so` uses **VMProtect** code virtualization, making binary patching impractical.

## Solution

**`ysm-java`** package in `~/nixos-config/packages/ysm-java/` provides three things:

### 1. Temurin 21 JRE (fetched from Adoptium)
Fetched directly as a tarball, **not** from nixpkgs. This preserves `java.vendor = Eclipse Adoptium`
(no err:54 from nixpkgs patching).

### 2. `libysm-fix.so` — LD_PRELOAD
Compiled from `ysm-fix.c`. The `dlopen` interceptor patches `JNI_OnLoad` with a trampoline
to a wrapper that:

1. **Sleeps 1.5s** before calling the real JNI_OnLoad (passes the time-dependent err:56 check)
2. **Calls the real JNI_OnLoad** — if DRM passes, all natives are registered normally
3. **If JNI_OnLoad still throws** — clears exception, replays 6 captured RegisterNatives
   entries as a fallback (captured from distrobox using RegisterNatives function table hooking)

### 3. `ysm-java` wrapper script
Sets `LD_PRELOAD=libysm-fix.so` and `LD_LIBRARY_PATH` for the GCC libs, then execs the
Temurin JRE's `java`. Install via `environment.systemPackages` so it's in `$PATH`.

## Usage

```bash
# On the host (asusg16):
ysm-java @user_jvm_args.txt @libraries/net/neoforged/neoforge/21.1.241/unix_args.txt --nogui

# Or via run.sh (which calls ysm-java):
./run.sh --nogui
```

## Build & rebuild

```bash
cd ~/nixos-config
nix-build -E '(import <nixpkgs> {}).callPackage ./packages/ysm-java {}'

# Or rebuild the whole system:
sudo nixos-rebuild switch --flake ~/nixos-config#asusg16
```

The package is added to `environment.systemPackages` in the host config:
`~/nixos-config/hosts/asusg16/packages/default.nix`.

## Files

```
~/nixos-config/packages/ysm-java/
├── default.nix   — Nix derivation
├── ysm-fix.c     — LD_PRELOAD source (1.5s delay + RegisterNatives replay)
└── README.md     — This file

~/.ysm/
├── libysm-fix.so                          — Compiled LD_PRELOAD
├── ysm-fix.c                              — Source copy
├── libysm-capture.so                      — RegisterNatives capturer (reference)
├── libysm-core-2.6.5-neoforge+mc1.21.1.so — YSM native lib for testing
├── libysm-core-2.6.5-forge+mc1.20.1.so    — YSM native lib (Forge)
└── YSM-NIXOS-HACKING.md                   — Full research notes
```

## NixOS Service VM

The VM (`nixos-service-vm`) also has `ysm-java` configured:

- **`~/nixos-config/hosts/nixos-service-vm/packages/default.nix`** — adds `ysm-java`
- **`~/nixos-config/hosts/nixos-service-vm/services/helloneojournautics.nix`** — uses
  `ysm-java` in the systemd service PATH for the Minecraft server
- **`~/Projects/HelloNeoJournautics/run.sh`** — updated to call `ysm-java` directly

## How the fix was discovered

The err:56 check is **time-dependent**. Testing in a distrobox showed:

```
t=0s:  RuntimeException: err: 56   ← fails immediately
t=1s:  SUCCESS                      ← passes after 1s
t=2s:  SUCCESS
t=3s:  SUCCESS
```

The exact environmental factor being checked isn't identified (the code is VMProtected),
but it consistently passes after ~1 second of JVM uptime. A 1.5s `nanosleep` in the
JNI_OnLoad wrapper is sufficient.

## Captured native methods (6/17)

Only the 6 methods registered during server startup were captured. The remaining 11
(client-side rendering, model data processing) are registered when their classes load
during normal operation — JNI_OnLoad registers them all at once when it succeeds.

```
O0Ooo000O0ooO00Oooo00oOO (4 methods at 0x3c2b30, 0x3c53a0, 0x3c5710, 0x3c6c50)
oo0OooOo00000oo0o0o0oOoo (2 methods at 0x3c23b0, 0x3c2520)
```

## Updating the capture data

If a new YSM version changes method name obfuscation or function offsets, re-capture:

1. Build `libysm-capture.so` inside a distrobox (or any environment where YSM's native
   lib loads successfully)
2. Run the server with `LD_PRELOAD=libysm-capture.so` to log RegisterNatives calls
3. Update the offsets in `ysm-fix.c`
