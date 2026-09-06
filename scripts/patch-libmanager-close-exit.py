#!/usr/bin/env python3
"""Make Cadence tools avoid the Xwayland damage-extension freeze on close/exit.

Closing a Cadence window unmaps it, and on Xwayland the unmap triggers a
composite unredirect (`compUnrealizeWindow → compRestoreWindow → damageCopyArea
→ damageRegionProcessPending`) that spins on a circular damage list and freezes
the DE. The DESTROY path (`compDestroyWindow`) does NOT do that restore, so
destroying/quit-ing is safe while unmap/minimize is not. A source-level Xwayland
fix is blocked by the read-only Nix store, so instead we change the client
behavior: replace the unmap paths with destroy/quit.

  libManager   cdsLibManager::fileExit     vaddr 0x5fb508  off 0x1fb508
               75 0e -> 90 90               (File→Exit always quit()s, no hide)
  cdsLibEditor cdsLibEditorExit             vaddr 0x56321e  off 0x16321e
               74 08 -> eb 08               (exit skips the mainWidget->hide())
  virtuoso     XIconifyWindow@plt           vaddr 0x56f7220 off 0x52f7220
               ff 25 .. -> e9 <jmp XDestroyWindow@plt> 90   (minimize -> destroy)
  virtuoso     XWithdrawWindow@plt          vaddr 0x5710750 off 0x5310750
               ff 25 .. -> e9 <jmp XDestroyWindow@plt> 90   (withdraw -> destroy)

Offsets are only valid for the exact IC25.1 binaries (libManager 16,440,520 B,
cdsLibEditor 12,600,720 B, virtuoso 115 MB); re-verify if the install changes.
Idempotent; backs each file up to `<name>.pre-close-exit` on first change.

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
        (0x1FB508, b"\x75\x0e", b"\x90\x90"),
    ],
    "tools/dfII/bin/64bit/cdsLibEditor": [
        (0x16321E, b"\x74\x08", b"\xeb\x08"),
    ],
    "tools/dfII/bin/64bit/virtuoso": [
        (0x52F7220, b"\xff\x25\xca\xfe\x25\x23", b"\xe9\x8b\x3c\xff\xff\x90"),
        (0x5310750, b"\xff\x25\x32\x34\x25\x23", b"\xe9\x5b\xa7\xfd\xff\x90"),
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
