#!/usr/bin/env python3
"""Fix the ~135s `virtuoso` launch stall on the macbook FEX setup.

Root cause: during the Cadence Qt style init, `QCadenceStyle::cdsRoot()`
runs `cds_root` through `QProcess` and calls `waitForStarted(30000)` /
`waitForFinished(30000)`, and `QProcess::~QProcess()` (in libcdsQt5Core)
calls `kill()` + `waitForFinished(30000)`. Under FEX these waits never
observe the child process as ready, so each blocks the full 30s (~4x =
~120s). Patching the 30000 (0x7530) timeout immediate down to 2000 (0x7d0)
drops the launch to ~26s.

The patches are to the *installed* Cadence tree (`~/.cadence/IC251`), which
is user data not managed by Nix, so they must be (re-)applied after a
reinstall/re-extract of the install. Each site is a x86_64 `mov $0x7530,%esi`
(`be 30 75 00 00`) — the timeout argument to `QProcess::waitForStarted/Finished`.

Sites (file offsets in the ELF, equal to VMA because the binaries are non-PIE):
  tools.lnx86/dfII/bin/64bit/virtuoso
      QCadenceStyle::cdsRoot  waitForStarted / waitForFinished
          0x1e9611fb / 0x1e961248
      9 further QProcess::waitForStarted/Finished(30000) call sites
          0x11f9d078 0x11fe9447 0x120ca32f 0x120cacf6 0x121db625   (waitForStarted)
          0xc167401  0x120ca350 0x120cad18 0x121db8d0              (waitForFinished)
  tools.lnx86/Qt/v5/64bit/lib/libcdsQt5Core.so.5.15.9
      QProcess::~QProcess  waitForFinished
          0x252688

Usage:
  python3 patch-cadence-qprocess-timeout.py [install-root]   apply (idempotent)
  python3 patch-cadence-qprocess-timeout.py --check [root]   report state
  python3 patch-cadence-qprocess-timeout.py --revert [root]  undo (30000 -> 2000 back to 30000)

Each changed file is backed up next to itself as `<name>.pre-qprocess-timeout`
(only on first change, so a pristine copy is preserved).
"""
import os
import sys

OLD = b"\xbe\x30\x75\x00\x00"  # mov $0x7530,%esi  (30000 ms)
NEW = b"\xbe\xd0\x07\x00\x00"  # mov $0x7d0,%esi   (2000 ms)

VIRTUOSO = "tools.lnx86/dfII/bin/64bit/virtuoso"
QTCORE = "tools.lnx86/Qt/v5/64bit/lib/libcdsQt5Core.so.5.15.9"

SITES = {
    VIRTUOSO: [
        0x1E9611FB, 0x1E961248,  # QCadenceStyle::cdsRoot waitForStarted/Finished
        0x11F9D078, 0x11FE9447, 0x120CA32F, 0x120CACF6, 0x121DB625,  # waitForStarted
        0x0C167401, 0x120CA350, 0x120CAD18, 0x121DB8D0,  # waitForFinished
    ],
    QTCORE: [0x252688],
}


def load(path):
    with open(path, "rb") as f:
        return bytearray(f.read())


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def back_up(path):
    backup = path + ".pre-qprocess-timeout"
    if not os.path.exists(backup):
        # real copy (not a symlink) so it survives later patches
        with open(path, "rb") as src, open(backup, "wb") as dst:
            dst.write(src.read())
        print(f"  backed up -> {backup}")
    return backup


def apply(root):
    for rel, sites in SITES.items():
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print(f"  MISSING {path}, skipping")
            continue
        data = load(path)
        changed = 0
        for off in sites:
            cur = bytes(data[off : off + 5])
            if cur == OLD:
                data[off : off + 5] = NEW
                changed += 1
            elif cur != NEW:
                print(f"  WARN {rel}:0x{off:x} unexpected bytes {cur.hex()}")
        if changed:
            back_up(path)
            write(path, data)
        print(f"{rel}: {changed} patched, {len(sites) - changed} already done")


def check(root):
    ok = True
    for rel, sites in SITES.items():
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print(f"  MISSING {path}")
            ok = False
            continue
        data = load(path)
        patched = sum(1 for off in sites if bytes(data[off : off + 5]) == NEW)
        print(f"{rel}: {patched}/{len(sites)} patched")
        if patched != len(sites):
            ok = False
    print("OK" if ok else "INCOMPLETE")
    return ok


def revert(root):
    for rel, sites in SITES.items():
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print(f"  MISSING {path}, skipping")
            continue
        data = load(path)
        changed = 0
        for off in sites:
            if bytes(data[off : off + 5]) == NEW:
                data[off : off + 5] = OLD
                changed += 1
        if changed:
            write(path, data)
        print(f"{rel}: reverted {changed} site(s)")


def main():
    args = sys.argv[1:]
    mode = "apply"
    if args and args[0] in ("--check", "--revert"):
        mode = args[0][2:]
        args = args[1:]
    root = args[0] if args else os.path.expanduser("~/.cadence/IC251")
    root = os.path.abspath(root)
    print(f"install root: {root}")
    if mode == "apply":
        apply(root)
    elif mode == "check":
        return 0 if check(root) else 1
    elif mode == "revert":
        revert(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
