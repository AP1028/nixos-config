#!/usr/bin/env python3
"""NOP the GC CopyArea blit inside Xwayland's compRestoreWindow.

Root cause of the Cadence DE-freeze (docs/cadence-freeze.md): when a client
with a corrupted composite damage chain disconnects, Xwayland's dispatch
thread spins forever in

  DeleteWindow -> compUnrealizeWindow -> compCheckRedirect
    -> compRestoreWindow -> damageCopyArea -> damageRegionProcessPending

The only door to that spin is the GC CopyArea blit compRestoreWindow issues
on unrealize. NOPing it skips just the (cosmetic, in a compositing session)
restore copy while keeping all of compRestoreWindow's bookkeeping, which
makes the spin unreachable.

The site is located structurally from the ELF symbol table, not from a
baked-in file offset:

  1. read compRestoreWindow's address and size out of .symtab
  2. find the unique GC-ops CopyArea call inside its address range:
       x86_64   call *0x18(%rax)              ff 50 18       -> 90 90 90
       aarch64  ldr xN, [xM, #0x18]; blr xN   f940.., d63f.. -> d503201f (nop)
     (0x18 is the arch-independent ops->CopyArea offset in the GC ops
     struct; on aarch64 the blr can be a few instructions after the ldr)

Missing symbols, zero or several candidates, or unexpected bytes abort with
a nonzero exit before anything is written - a changed Xwayland stops the
build instead of being blind-patched. If that happens, re-derive manually:

  nm -S <Xwayland> | grep compRestoreWindow
  objdump -d --start-address=<addr> --stop-address=<addr+size> <Xwayland>

Usage: patch-xwayland-comp-restore.py [--dry-run] <Xwayland>
"""

import struct
import sys

PT_LOAD = 1
SHT_SYMTAB = 2
SHT_DYNSYM = 11
EM_X86_64 = 62
EM_AARCH64 = 183


class Elf:
    """Just enough ELF64 parsing to map addresses and read symbols."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        d = self.data
        if d[:4] != b"\x7fELF":
            raise ValueError(f"{path}: not an ELF file")
        if d[4] != 2 or d[5] != 1:
            raise ValueError(f"{path}: only 64-bit little-endian ELF is supported")
        (
            self.e_type,
            self.e_machine,
            _e_version,
            _e_entry,
            self.e_phoff,
            self.e_shoff,
            _e_flags,
            _e_ehsize,
            self.e_phentsize,
            self.e_phnum,
            self.e_shentsize,
            self.e_shnum,
            _e_shstrndx,
        ) = struct.unpack_from("<HHIQQQIHHHHHH", d, 0x10)
        self.loads = []
        for i in range(self.e_phnum):
            p = struct.unpack_from("<IIQQQQQQ", d, self.e_phoff + i * self.e_phentsize)
            if p[0] == PT_LOAD:
                self.loads.append((p[3], p[2], p[5]))  # vaddr, file offset, filesz

    def offset_to_vaddr(self, offset):
        for vaddr, file_off, filesz in self.loads:
            if file_off <= offset < file_off + filesz:
                return vaddr + offset - file_off
        raise ValueError(f"file offset 0x{offset:x} is not in a PT_LOAD segment")

    def vaddr_to_offset(self, vaddr):
        for p_vaddr, file_off, filesz in self.loads:
            if p_vaddr <= vaddr < p_vaddr + filesz:
                return file_off + vaddr - p_vaddr
        raise ValueError(f"vaddr 0x{vaddr:x} is not in a PT_LOAD segment")

    def symbol(self, name):
        sections = [
            struct.unpack_from(
                "<IIQQQQIIQQ", self.data, self.e_shoff + i * self.e_shentsize
            )
            for i in range(self.e_shnum)
        ]
        for sh in sections:
            sh_type, sh_offset, sh_size, sh_link, sh_entsize = (
                sh[1],
                sh[4],
                sh[5],
                sh[6],
                sh[9],
            )
            if sh_type not in (SHT_SYMTAB, SHT_DYNSYM) or not sh_entsize:
                continue
            str_off = sections[sh_link][4]
            for j in range(sh_size // sh_entsize):
                st_name, _, _, st_shndx, st_value, st_size = struct.unpack_from(
                    "<IBBHQQ", self.data, sh_offset + j * sh_entsize
                )
                if st_name == 0 or st_shndx == 0:
                    continue
                end = self.data.find(b"\0", str_off + st_name)
                if self.data[str_off + st_name : end] == name.encode():
                    return st_value, st_size
        raise ValueError(f"{self.path}: symbol {name!r} not found (stripped binary?)")


def find_site(elf):
    """Return (file_offset, old_bytes, new_bytes, description)."""
    func_vaddr, func_size = elf.symbol("compRestoreWindow")
    if func_size == 0:
        raise ValueError("compRestoreWindow has size 0 in the symbol table")
    start = elf.vaddr_to_offset(func_vaddr)
    end = start + func_size
    d = elf.data

    if elf.e_machine == EM_X86_64:
        old, new = b"\xff\x50\x18", b"\x90\x90\x90"
        matches = [
            i for i in range(start, end - len(old) + 1) if d[i : i + len(old)] == old
        ]
        desc = "x86_64 call *0x18(%rax)"
    elif elf.e_machine == EM_AARCH64:
        old = None
        new = struct.pack("<I", 0xD503201F)  # nop
        matches = []
        for i in range(start, end - 3, 4):
            w0 = struct.unpack_from("<I", d, i)[0]
            # ldr xN, [xM, #0x18]: 64-bit unsigned-offset load, imm12 == 3
            if (w0 & 0xFFC00000) != 0xF9400000 or ((w0 >> 10) & 0xFFF) != 3:
                continue
            rt = w0 & 0x1F
            for j in range(1, 5):
                if i + 4 * j + 4 > end:
                    break
                w1 = struct.unpack_from("<I", d, i + 4 * j)[0]
                if w1 == (0xD63F0000 | (rt << 5)):
                    matches.append(i + 4 * j)
                    break
                # stop at any intervening call/branch/return
                if (
                    (w1 & 0xFC000000) in (0x94000000, 0x14000000)
                    or (w1 & 0xFFFFFC1F) == 0xD63F0000
                    or w1 == 0xD65F03C0
                ):
                    break
        desc = "aarch64 blr xN after ldr xN,[xM,#0x18]"
    else:
        raise ValueError(
            f"unsupported ELF machine {elf.e_machine} (need x86_64 or aarch64)"
        )

    if len(matches) != 1:
        where = (
            ", ".join(f"0x{elf.offset_to_vaddr(m):x}" for m in matches) or "none"
        )
        raise ValueError(
            "expected exactly one CopyArea site inside compRestoreWindow, "
            f"found {len(matches)}: {where}"
        )
    off = matches[0]
    if old is None:
        old = bytes(d[off : off + len(new)])
    return off, old, new, desc


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    paths = [a for a in args if not a.startswith("--")]
    if len(paths) != 1 or any(a != "--dry-run" for a in args if a.startswith("--")):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = paths[0]
    elf = Elf(path)
    off, old, new, desc = find_site(elf)
    vaddr = elf.offset_to_vaddr(off)
    if bytes(elf.data[off : off + len(old)]) != old:
        raise ValueError(
            f"unexpected bytes at file 0x{off:x}: "
            f"{bytes(elf.data[off : off + len(old)]).hex()}, expected {old.hex()}"
        )
    if not dry_run:
        elf.data[off : off + len(new)] = new
        with open(path, "wb") as f:
            f.write(elf.data)
    print(
        f"{path}: {'would patch' if dry_run else 'patched'} "
        f"file 0x{off:x} / vaddr 0x{vaddr:x} ({desc}): {old.hex()} -> {new.hex()}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as e:
        sys.exit(f"error: {e}")
