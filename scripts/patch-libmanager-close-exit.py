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
  libManager   _qtWinCloser::eventFilter   vaddr 0x71c1f3  off 0x31c1f3
               e8 (call hide@plt) -> 90 90 90 90 90
                                            (libSelect close: no unmap before cancel)
  libManager   _qtWinCloser::eventFilter   vaddr 0x71c251  off 0x31c251
               e8 (call hide@plt) -> 90 90 90 90 90
                                            (no unmap before fileExit→quit)
  libManager   _qtWinCloser::eventFilter   vaddr 0x71c2b7  off 0x31c2b7
               e8 (call showMinimized@plt) -> e8 (call QCoreApplication::quit@plt)
                                            (close with clients attached: quit,
                                             don't iconify)
  cdsLibEditor cdsLibEditorExit             vaddr 0x56321e  off 0x16321e
               74 08 -> eb 08               (exit skips the mainWidget->hide())
  cdsLibEditor _qtWinCloser::eventFilter   vaddr 0x55726f  off 0x15726f
               e8 (call hide@plt) -> 90 90 90 90 90
                                            (X button: no unmap before fileExit→quit)
  libManager   cdslibmanExit                vaddr 0x71a64a  off 0x31a64a
               e8 (call hide@plt) -> 90 90 90 90 90
                                            (exit: hide() unmaps BEFORE the safe
                                             delete-widget/delete-qApp teardown)
  libManager   killHidden                   vaddr 0x719939  off 0x319939
               e8 (call close@plt) -> 90 90 90 90 90
                                            (close() = closeEvent = hide = unmap)
  cdsLibEditor killHidden                   vaddr 0x5572b7  off 0x1572b7
               e8 (call close@plt) -> 90 90 90 90 90
  cdsLibEditor killHidden                   vaddr 0x5572f9  off 0x1572f9
               e8 (call hide@plt) -> 90 90 90 90 90
  cdsLibEditor cdsLibEditorUnmap            vaddr 0x5628dc  off 0x1628dc
               e8 (call hide@plt) -> 90 90 90 90 90   (no callers; dead code)
  cdsLibEditor cdsLibEditorShutdown         vaddr 0x56293c  off 0x16293c
               e8 (call hide@plt) -> 90 90 90 90 90
  cdsLibEditor wrapVoExit                   vaddr 0x5578dc  off 0x1578dc
               e8 (call hide@plt) -> 90 90 90 90 90
                                            (hide before delete widget/quit/delete
                                             qApp — the deletes are the safe part)
  virtuoso     XIconifyWindow@plt           vaddr 0x56f7220 off 0x52f7220
               ff 25 .. -> e9 <jmp XDestroyWindow@plt> 90   (minimize -> destroy)
  virtuoso     XWithdrawWindow@plt          vaddr 0x5710750 off 0x5310750
               ff 25 .. -> e9 <jmp XDestroyWindow@plt> 90   (withdraw -> destroy)

The Qt close paths never call XIconifyWindow directly: _qtWinCloser::eventFilter
intercepts QEvent::Close and hides (xcb_unmap_window) or showMinimized()s
(WM_CHANGE_STATE) — both land in the Xwayland unmap path that spins. NOPing the
hide is required (fileExit/libSelectCancelSlot is called on the same widget right
after, so deleteLater would be a use-after-free); the iconify branch instead
calls quit(), and everything is destroyed via the X connection close.

Offsets are only valid for the exact IC25.1 binaries (libManager 16,440,520 B,
cdsLibEditor 12,600,720 B, virtuoso 818,274,452 B); re-verify if the install
changes. Idempotent; backs each file up to `<name>.pre-close-exit` on first
change.

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
        # _qtWinCloser::eventFilter: call hide@plt (0x562790) x2 -> nops
        (0x31C1F3, b"\xe8\x98\x65\xe4\xff", b"\x90\x90\x90\x90\x90"),
        (0x31C251, b"\xe8\x3a\x65\xe4\xff", b"\x90\x90\x90\x90\x90"),
        # _qtWinCloser::eventFilter: call showMinimized@plt -> call quit@plt
        # (0x562560; disp 0xffe462a4 from next-insn 0x71c2bc)
        (0x31C2B7, b"\xe8\x04\x58\xe4\xff", b"\xe8\xa4\x62\xe4\xff"),
        # exit-path unmap removal: hide()/close() unmap (-> spin) before the
        # safe delete-widget/delete-qApp teardown; NOPing leaves only the
        # per-window destroys (compDestroyWindow-safe) + windowless conn close
        (0x31A64A, b"\xe8\x41\x81\xe4\xff", b"\x90\x90\x90\x90\x90"),
        (0x319939, b"\xe8\x42\xca\xe4\xff", b"\x90\x90\x90\x90\x90"),
    ],
    "tools/dfII/bin/64bit/cdsLibEditor": [
        (0x16321E, b"\x74\x08", b"\xeb\x08"),
        # _qtWinCloser::eventFilter: call hide@plt (0x4f2ec0) -> nops
        (0x15726F, b"\xe8\x4c\xbc\xf9\xff", b"\x90\x90\x90\x90\x90"),
        # exit-path unmap removal (see libManager comment)
        (0x1572B7, b"\xe8\x24\xe0\xf9\xff", b"\x90\x90\x90\x90\x90"),
        (0x1572F9, b"\xe8\xc2\xbb\xf9\xff", b"\x90\x90\x90\x90\x90"),
        (0x1628DC, b"\xe8\xdf\x05\xf9\xff", b"\x90\x90\x90\x90\x90"),
        (0x16293C, b"\xe8\x7f\x05\xf9\xff", b"\x90\x90\x90\x90\x90"),
        (0x1578DC, b"\xe8\xdf\xb5\xf9\xff", b"\x90\x90\x90\x90\x90"),
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
