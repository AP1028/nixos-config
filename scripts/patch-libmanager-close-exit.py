#!/usr/bin/env python3
"""Make libManager's close (X) button EXIT instead of hide/minimize.

By default `cdsLibManager::closeEvent` only quits when `mpsOpWaiting == 0`;
when an MPS operation is pending (the normal case under FEX/box64, where the
MPS daemons are always busy) it instead calls `QWidget::hide()` — the
"pseudo-minimize" — which unmaps the window and, on Xwayland, can hit the
damage-extension busy loop that freezes the whole DE (see docs/cadence-fex.md
"UNRESOLVED"). Patch the branch so close always quits:

    cdsLibManager::closeEvent   vaddr 0x603e3a  (file offset 0x203e3a)
      85 c0        test %eax,%eax      ; mpsOpWaiting
      74 1c        je   +0x1c          ;  ->  eb 1c  (jmp, always quit)
      48 89 df     mov  %rbx,%rdi
      e8 ...       call QWidget::hide  ;  (dead after patch)

Only valid for the exact IC25.1 `libManager` (16,440,520 bytes, non-PIE ELF);
re-verify the offset if the install is updated. Idempotent; backs the file up
to `<name>.pre-close-exit` on first change (a real copy, not a symlink).

Usage:
  python3 patch-libmanager-close-exit.py            # apply
  python3 patch-libmanager-close-exit.py --check    # report state
  python3 patch-libmanager-close-exit.py --revert   # restore the backup
"""

import os
import sys

ROOT = os.path.expanduser("~/.cadence/IC251")

# rel path -> [(file offset, expected old bytes, new bytes)]
SITES = {
    "tools/dfII/bin/64bit/libManager": [(0x203E3A, b"\x74\x1c", b"\xeb\x1c")],
}

BACKUP_SUFFIX = ".pre-close-exit"


def load(path):
    with open(path, "rb") as f:
        return bytearray(f.read())


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def back_up(path):
    backup = path + BACKUP_SUFFIX
    if not os.path.exists(backup):
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
        for off, old, new in sites:
            cur = bytes(data[off : off + len(old)])
            if cur == old:
                data[off : off + len(new)] = new
                changed += 1
            elif cur != new:
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
        patched = sum(
            1 for off, old, new in sites if bytes(data[off : off + len(new)]) == new
        )
        print(f"{rel}: {patched}/{len(sites)} patched")
        if patched != len(sites):
            ok = False
    print("OK" if ok else "NOT OK")


def revert(root):
    for rel in SITES:
        path = os.path.join(root, rel)
        backup = path + BACKUP_SUFFIX
        if os.path.exists(backup):
            write(path, load(backup))
            print(f"{rel}: reverted from {BACKUP_SUFFIX}")
        else:
            print(f"{rel}: no backup, nothing to revert")


def main():
    if "--check" in sys.argv:
        check(ROOT)
    elif "--revert" in sys.argv:
        revert(ROOT)
    else:
        apply(ROOT)


if __name__ == "__main__":
    main()
