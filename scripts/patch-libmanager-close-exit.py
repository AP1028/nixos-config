#!/usr/bin/env python3
"""Make Cadence lib tools close cleanly instead of crashing the DE / CIW.

The X (close) button and File→Exit can crash/hang: the close path either
`showMinimized()`s or `hide()`+`fileExit()`s, both of which unmap the window
(damage busy-loop → DE freeze) and the exit path also hangs the parent CIW.
Three patches fix this:

1. libManager close (X): its `_qtWinCloser` event filter intercepts
   `QEvent::Close`; overwrite the filter entry with `mov $1,%eax; ret` so it
   returns true (consumes the event). `QCloseEvent` defaults to accepted, so Qt
   closes via its native path (hide+destroy) — no crash.
2. libManager File→Exit: `cdsLibManager::fileExit()` does
   `mpsOpWaiting ? QWidget::hide() : quit()`; the hide branch is the crash
   trigger. NOP the `jne` so it always quits cleanly.
3. cdsLibEditor close (X): it has its own `cdsLibEditor::closeEvent` (not the
   `_qtWinCloser` filter), which disables widgets, runs the exit callback, and
   `hide()`s+`closeAllWindows()`. NOP the `doingExit`-guard `je` so closeEvent
   returns immediately and Qt closes via its native path — no crash.

Targets (all under ~/.cadence/IC251):
  tools/dfII/bin/64bit/libManager     # == libSelect (same inode), "Library Manager"
  tools/dfII/bin/64bit/cdsLibEditor   # "Library Editor"

  libManager   _qtWinCloser::eventFilter  vaddr 0x71c150  off 0x31c150
               55 bf e0 c8 ed 00  ->  b8 01 00 00 00 c3   (return true)
  libManager   cdsLibManager::fileExit    vaddr 0x5fb508  off 0x1fb508
               75 0e              ->  90 90               (always quit)
  cdsLibEditor cdsLibEditor::closeEvent   vaddr 0x539221  off 0x139221
               74 05              ->  90 90               (always return -> native close)

Offsets are only valid for the exact IC25.1 binaries (libManager 16,440,520 B,
cdsLibEditor 12,600,720 B); re-verify if the install is updated. Idempotent;
backs each file up to `<name>.pre-close-exit` on first change.

Usage:
  python3 patch-libmanager-close-exit.py            # apply
  python3 patch-libmanager-close-exit.py --check    # report state
  python3 patch-libmanager-close-exit.py --revert   # restore the backups
"""

import os
import sys

ROOT = os.path.expanduser("~/.cadence/IC251")

# rel path -> [(file offset, expected old bytes, new bytes)]
SITES = {
    "tools/dfII/bin/64bit/libManager": [
        (0x31C150, b"\x55\xbf\xe0\xc8\xed\x00", b"\xb8\x01\x00\x00\x00\xc3"),
        (0x1FB508, b"\x75\x0e", b"\x90\x90"),
    ],
    "tools/dfII/bin/64bit/cdsLibEditor": [
        (0x139221, b"\x74\x05", b"\x90\x90"),
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
