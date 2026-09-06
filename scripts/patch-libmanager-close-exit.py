#!/usr/bin/env python3
"""Make Cadence lib tools' close (X) button do nothing, to avoid the DE freeze.

Closing a lib tool's window unmaps it and hits an Xwayland damage-extension
race (a circular damage list makes `damageRegionProcessPending` spin) that
freezes the whole desktop; the `hide()`+`fileExit()` path additionally hangs the
parent Virtuoso CIW. A source-level Xwayland fix is blocked by the Nix read-only
store, so instead we make the close button a no-op: swallow the `QEvent::Close`
and mark it ignored, so Qt never unmaps the window and neither crash can be
triggered by accident. File→Exit still quits cleanly.

Qt 5.15 `QEvent`: `m_accept` is bit 2 (0x04) at offset 0x12, so
`andb $0xfb, 0x12(%event)` == `event->ignore()`.

  libManager   _qtWinCloser::eventFilter  vaddr 0x71c150  off 0x31c150
               55 bf e0 c8 ed 00 48 89 e5 41
               -> 80 62 12 fb b8 01 00 00 00 c3   (ignore Close; return true)
  libManager   cdsLibManager::fileExit    vaddr 0x5fb508  off 0x1fb508
               75 0e -> 90 90                      (File→Exit always quit()s)
  cdsLibEditor cdsLibEditor::closeEvent   vaddr 0x539210  off 0x139210
               8b 05 9a 62 97 -> 80 66 12 fb c3     (ignore Close; return)

libManager == libSelect (same inode). Offsets valid only for the exact IC25.1
binaries (libManager 16,440,520 B, cdsLibEditor 12,600,720 B); re-verify if the
install changes. Idempotent; backs up to `<name>.pre-close-exit`.

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
        (0x31C150, b"\x55\xbf\xe0\xc8\xed\x00\x48\x89\xe5\x41", b"\x80\x62\x12\xfb\xb8\x01\x00\x00\x00\xc3"),
        (0x1FB508, b"\x75\x0e", b"\x90\x90"),
    ],
    "tools/dfII/bin/64bit/cdsLibEditor": [
        (0x139210, b"\x8b\x05\x9a\x62\x97", b"\x80\x66\x12\xfb\xc3"),
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
