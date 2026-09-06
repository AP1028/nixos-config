#!/usr/bin/env python3
"""Make libManager's close (X) button do nothing (consume the Close event).

The Library Manager does NOT use `QWidget::closeEvent` for the X button.
`cdsLibManager` installs a `_qtWinCloser` event filter that intercepts
`QEvent::Close` and either calls `showMinimized()` or `hide()`+`fileExit()`.
Both paths unmap/destroy the window and can hit the Xwayland damage busy-loop
that freezes the DE, and the exit path also makes the parent Virtuoso CIW hang
(see docs/cadence-fex.md "UNRESOLVED"). So instead we swallow the Close event
entirely: the filter returns true immediately without touching the window, so
clicking X does nothing and neither crash can be triggered by accident.

    _qtWinCloser::eventFilter   vaddr 0x71c150  (file offset 0x31c150)
      55 bf e0 c8 ed 00   push %rbp; mov $0xedc8e0,%edi
       ->  b8 01 00 00 00 c3   mov $1,%eax; ret   (return true = consume Close)

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
    "tools/dfII/bin/64bit/libManager": [
        (0x31C150, b"\x55\xbf\xe0\xc8\xed\x00", b"\xb8\x01\x00\x00\x00\xc3"),
    ],
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
