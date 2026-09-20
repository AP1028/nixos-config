#!/usr/bin/env python3
"""Harden Xwayland's damage-list walk against corrupt damage lists.

See docs/cadence-freeze.md, section "TODO: same corruption now crashes
Xwayland". Xwayland's damage extension keeps a per-pixmap list of DamageRecs.
An upstream bookkeeping bug can leave a freed DamageRec linked in the list;
the next damage-wrapped draw op that walks the list -- e.g.

    ProcShmPutImage -> damagePutImage -> damageRegionProcessPending

-- dereferences the stale node and segfaults the whole X server, killing every
X client. The compRestoreWindow bypass (patch-xwayland-comp-restore.py)
removed the walk that used to *freeze* on the same corrupt list; this patch
stops the crash.

Before a node is used, a stub checks that it still looks like a DamageRec on
the expected screen:

    pDamage->pScreen     == pDrawable->pScreen    (DamageRec+0x68)
    pDamage->damageLevel <= DamageReportNone (4)  (DamageRec+0x20)
    pDamage->reportAfter <= 1                     (DamageRec+0x50)

If a check fails the walk stops. The checks run before pDamage->pNext is
followed, so a garbage node's link is never dereferenced.

Implementation (x86_64 only):

  * hook A: the call to getDrawableDamageRef() inside the function is replaced
    by a jump to a stub that saves pDrawable->pScreen in the function's spare
    stack slot ([rbp-0x10]) and then performs the call.
  * hook B: the loop head (mov 0x50(%rbx),%edx; test %edx,%edx) is replaced
    by a jump to a stub that validates the current pDamage against the saved
    screen, then replays the two overwritten instructions.

The stubs live in the zero padding at the end of the executable PT_LOAD (the
page that contains the tail of .fini), so no section or segment has to grow.

Everything is found structurally, nothing is baked in:

  * damageRegionProcessPending / getDrawableDamageRef / DamageReportDamage
    come from .symtab;
  * hook A is the unique direct call to getDrawableDamageRef inside the
    function;
  * the loop head is the branch target of the "if (pDamage) goto loop" test
    that follows that call;
  * the exit is the function's unique epilogue (mov -0x8(%rbp),%rbx; leave);
  * the field offsets are pinned by the code itself: reportAfter by the
    loop-head pattern, damageLevel (<= 4) by DamageReportDamage's
    "cmpl $4,0x20(%rdi); ja".

Missing symbols or changed patterns abort with a nonzero exit before anything
is written, so a nixpkgs bump fails the build instead of blind-patching.
aarch64 is not implemented yet: the script warns and leaves the binary
untouched so the macbook keeps building with the comp-restore bypass only.

Usage: patch-xwayland-damage-walk.py [--dry-run] <Xwayland>
"""

import struct
import sys

PT_LOAD = 1
SHT_SYMTAB = 2
SHT_DYNSYM = 11
SHT_NOBITS = 8
SHF_ALLOC = 0x2
EM_X86_64 = 62
EM_AARCH64 = 183

CAVE_SIZE = 0x50
STUB_B_OFFSET = 0x20


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
            e_shstrndx,
        ) = struct.unpack_from("<HHIQQQIHHHHHH", d, 0x10)
        self.loads = []
        for i in range(self.e_phnum):
            p = struct.unpack_from("<IIQQQQQQ", d, self.e_phoff + i * self.e_phentsize)
            if p[0] == PT_LOAD:
                self.loads.append(
                    {
                        "flags": p[1],
                        "offset": p[2],
                        "vaddr": p[3],
                        "filesz": p[5],
                        "memsz": p[6],
                    }
                )
        self.sections = []
        for i in range(self.e_shnum):
            sh = struct.unpack_from(
                "<IIQQQQIIQQ", d, self.e_shoff + i * self.e_shentsize
            )
            self.sections.append(
                {
                    "index": i,
                    "name_off": sh[0],
                    "type": sh[1],
                    "flags": sh[2],
                    "addr": sh[3],
                    "offset": sh[4],
                    "size": sh[5],
                }
            )
        shstr = self.sections[e_shstrndx]
        self.shstr = d[shstr["offset"] : shstr["offset"] + shstr["size"]]

    def section_name(self, sh):
        o = sh["name_off"]
        end = self.shstr.find(b"\0", o)
        return self.shstr[o:end].decode()

    def offset_to_vaddr(self, offset):
        for l in self.loads:
            if l["offset"] <= offset < l["offset"] + l["filesz"]:
                return l["vaddr"] + offset - l["offset"]
        raise ValueError(f"file offset 0x{offset:x} is not in a PT_LOAD segment")

    def vaddr_to_offset(self, vaddr):
        for l in self.loads:
            if l["vaddr"] <= vaddr < l["vaddr"] + l["filesz"]:
                return l["offset"] + vaddr - l["vaddr"]
        raise ValueError(f"vaddr 0x{vaddr:x} is not in a PT_LOAD segment")

    def symbol(self, name):
        for sh in self.sections:
            if sh["type"] not in (SHT_SYMTAB, SHT_DYNSYM) or not sh["size"]:
                continue
            # sh_link / sh_entsize are not kept in the dict; re-read them
            raw = struct.unpack_from(
                "<IIQQQQIIQQ",
                self.data,
                self.e_shoff + sh["index"] * self.e_shentsize,
            )
            sh_link, sh_entsize = raw[6], raw[9]
            if not sh_entsize:
                continue
            str_off = self.sections[sh_link]["offset"]
            for j in range(sh["size"] // sh_entsize):
                st_name, _, _, st_shndx, st_value, st_size = struct.unpack_from(
                    "<IBBHQQ", self.data, sh["offset"] + j * sh_entsize
                )
                if st_name == 0 or st_shndx == 0:
                    continue
                end = self.data.find(b"\0", str_off + st_name)
                if self.data[str_off + st_name : end] == name.encode():
                    return st_value, st_size
        raise ValueError(f"{self.path}: symbol {name!r} not found (stripped binary?)")

    def exec_load_containing(self, vaddr):
        for l in self.loads:
            if l["flags"] & 0x1 and l["vaddr"] <= vaddr < l["vaddr"] + l["memsz"]:
                return l
        raise ValueError(f"vaddr 0x{vaddr:x} is not in an executable PT_LOAD")


def rel32(src, dst):
    """Encode a rel32 operand for a jmp/call at src targeting dst."""
    delta = dst - (src + 5)
    if not -(1 << 31) <= delta < (1 << 31):
        raise ValueError(f"rel32 out of range: {src:#x} -> {dst:#x}")
    return struct.pack("<i", delta)


def find_sites(elf):
    """Locate the function, both hook sites and the exit label."""
    d = elf.data
    func_va, func_size = elf.symbol("damageRegionProcessPending")
    if func_size == 0:
        raise ValueError("damageRegionProcessPending has size 0")
    ref_va, _ = elf.symbol("getDrawableDamageRef")
    start = elf.vaddr_to_offset(func_va)
    end = start + func_size

    # hook A: the unique direct call to getDrawableDamageRef
    hook_a = None
    for i in range(start, end - 5):
        if d[i] != 0xE8:
            continue
        rel = struct.unpack_from("<i", d, i + 1)[0]
        if elf.offset_to_vaddr(i) + 5 + rel == ref_va:
            if hook_a is not None:
                raise ValueError("more than one call to getDrawableDamageRef")
            hook_a = i
    if hook_a is None:
        raise ValueError("no direct call to getDrawableDamageRef in the function")

    # loop head: target of the "if (pDamage) goto loop" test after hook A
    loop = None
    for i in range(hook_a + 5, end - 8):
        if d[i : i + 6] != b"\x48\x8b\x18\x48\x85\xdb" or d[i + 6] != 0x75:
            continue
        tgt = elf.offset_to_vaddr(i + 6) + 2 + struct.unpack_from("<b", d, i + 7)[0]
        if not (func_va <= tgt < func_va + func_size):
            continue
        if loop is not None:
            raise ValueError("more than one damage-list loop in the function")
        loop = elf.vaddr_to_offset(tgt)
    if loop is None:
        raise ValueError("could not find the damage-list loop head")
    if d[loop : loop + 5] != b"\x8b\x53\x50\x85\xd2" or d[loop + 5] != 0x74:
        raise ValueError(
            "loop head is not 'mov 0x50(%rbx),%edx; test %edx,%edx; je' "
            "(reportAfter offset changed?)"
        )

    # exit: the function's unique epilogue
    exits = [
        i
        for i in range(start, end - 4)
        if d[i : i + 5] == b"\x48\x8b\x5d\xf8\xc9"
    ]
    if len(exits) != 1:
        raise ValueError(f"expected one epilogue, found {len(exits)}")
    exit_va = elf.offset_to_vaddr(exits[0])

    # pin damageLevel offset/max via DamageReportDamage's own bound check
    drd_va, _ = elf.symbol("DamageReportDamage")
    drd = elf.vaddr_to_offset(drd_va)
    if b"\x83\x7f\x20\x04\x0f\x87" not in d[drd : drd + 0x40]:
        raise ValueError(
            "DamageReportDamage no longer checks 'cmpl $4,0x20(%rdi); ja' "
            "(damageLevel offset changed?)"
        )

    return func_va, hook_a, loop, exit_va, ref_va


def find_cave(elf, func_va):
    """Find zero padding at the end of the function's executable PT_LOAD."""
    seg = elf.exec_load_containing(func_va)
    seg_end = seg["vaddr"] + max(seg["filesz"], seg["memsz"])
    cave = (seg_end + 0xF) & ~0xF
    page_end = (seg_end + 0xFFF) & ~0xFFF
    if cave + CAVE_SIZE > page_end:
        raise ValueError(
            f"only {page_end - cave:#x} bytes of padding at the end of the "
            "executable segment; need {CAVE_SIZE:#x}"
        )

    # the padding page must not be mapped by another PT_LOAD
    for other in elf.loads:
        if other is seg:
            continue
        lo = other["vaddr"] & ~0xFFF
        hi = (
            other["vaddr"] + max(other["filesz"], other["memsz"]) + 0xFFF
        ) & ~0xFFF
        if lo < page_end and cave < hi:
            raise ValueError("executable padding page overlaps another PT_LOAD")

    off = seg["offset"] + (cave - seg["vaddr"])
    if off + CAVE_SIZE > len(elf.data):
        raise ValueError("cave would extend past the end of the file")

    # nothing may own those bytes: neither an allocated address range nor a
    # file-backed section
    for sh in elf.sections:
        if sh["type"] == SHT_NOBITS or sh["size"] == 0:
            continue
        if sh["flags"] & SHF_ALLOC:
            if sh["addr"] < cave + CAVE_SIZE and cave < sh["addr"] + sh["size"]:
                raise ValueError(
                    f"cave overlaps allocated section {elf.section_name(sh)!r}"
                )
        else:
            if sh["offset"] < off + CAVE_SIZE and off < sh["offset"] + sh["size"]:
                raise ValueError(
                    f"cave overlaps file section {elf.section_name(sh)!r}"
                )
    return cave, off


def build_stubs(cave, hook_a_va, loop_va, exit_va, ref_va):
    """Assemble the two stubs by hand (no external assembler)."""
    # stub A: save pDrawable->pScreen, then call getDrawableDamageRef
    stub_a = bytearray()
    stub_a += bytes.fromhex("488b4710")  # mov 0x10(%rdi),%rax
    stub_a += bytes.fromhex("488945f0")  # mov %rax,-0x10(%rbp)
    stub_a += b"\xe8" + rel32(cave + len(stub_a), ref_va)
    stub_a += b"\xe9" + rel32(cave + len(stub_a), hook_a_va + 5)
    if len(stub_a) > STUB_B_OFFSET:
        raise ValueError("stub A does not fit before stub B")

    # stub B: validate pDamage, then replay the overwritten instructions
    b = cave + STUB_B_OFFSET
    insns = []

    def emit(hexbytes):
        insns.append(bytes.fromhex(hexbytes))
        return len(insns) - 1

    emit("f6c30f")  # test $0xf,%bl           ; DamageRecs are malloc'd, 16-aligned
    idx_j1 = emit("7500")  # jne invalid
    emit("488b45f0")  # mov -0x10(%rbp),%rax
    emit("48394368")  # cmp %rax,0x68(%rbx)   ; pDamage->pScreen == screen
    idx_j2 = emit("7500")  # jne invalid
    emit("837b2004")  # cmpl $4,0x20(%rbx)    ; damageLevel <= DamageReportNone
    idx_j3 = emit("7700")  # ja invalid
    emit("837b5001")  # cmpl $1,0x50(%rbx)    ; reportAfter <= 1
    idx_j4 = emit("7700")  # ja invalid
    emit("8b5350")  # mov 0x50(%rbx),%edx     ; replay overwritten instructions
    emit("85d2")  # test %edx,%edx
    idx_jb = emit("e900000000")  # jmp loop_va+5
    idx_inv = emit("e900000000")  # invalid: jmp exit_va

    offs = []
    o = 0
    for i in insns:
        offs.append(o)
        o += len(i)
    code = bytearray(b"".join(insns))

    for j in (idx_j1, idx_j2, idx_j3, idx_j4):
        pos = offs[j]
        code[pos + 1] = offs[idx_inv] - pos - 2
    for j, tgt in ((idx_jb, loop_va + 5), (idx_inv, exit_va)):
        pos = offs[j]
        code[pos + 1 : pos + 5] = rel32(b + pos, tgt)

    stub_b = bytes(code)
    if STUB_B_OFFSET + len(stub_b) > CAVE_SIZE:
        raise ValueError("stubs do not fit in the cave")
    return bytes(stub_a), stub_b


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    paths = [a for a in args if not a.startswith("--")]
    if len(paths) != 1 or any(a != "--dry-run" for a in args if a.startswith("--")):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = paths[0]

    elf = Elf(path)
    if elf.e_machine == EM_AARCH64:
        print(
            f"{path}: aarch64 damage-walk hardening not implemented yet, "
            "leaving binary untouched",
            file=sys.stderr,
        )
        return 0
    if elf.e_machine != EM_X86_64:
        raise ValueError(f"unsupported ELF machine {elf.e_machine} (need x86_64)")

    func_va, hook_a, loop, exit_va, ref_va = find_sites(elf)
    hook_a_va = elf.offset_to_vaddr(hook_a)
    loop_va = elf.offset_to_vaddr(loop)
    cave, cave_off = find_cave(elf, func_va)
    stub_a, stub_b = build_stubs(cave, hook_a_va, loop_va, exit_va, ref_va)

    # verify the bytes we are about to replace
    d = elf.data
    old_a = bytes(d[hook_a : hook_a + 5])
    if old_a[0] != 0xE8:
        raise ValueError(f"unexpected bytes at hook A: {old_a.hex()}")
    old_b = bytes(d[loop : loop + 5])
    if old_b != b"\x8b\x53\x50\x85\xd2":
        raise ValueError(f"unexpected bytes at hook B: {old_b.hex()}")

    if not dry_run:
        d[hook_a : hook_a + 5] = b"\xe9" + rel32(hook_a_va, cave)
        d[loop : loop + 5] = b"\xe9" + rel32(loop_va, cave + STUB_B_OFFSET)
        d[cave_off : cave_off + len(stub_a)] = stub_a
        d[cave_off + STUB_B_OFFSET : cave_off + STUB_B_OFFSET + len(stub_b)] = stub_b
        with open(path, "wb") as f:
            f.write(d)

        # read back and verify
        check = Elf(path)
        c = check.data
        if bytes(c[hook_a : hook_a + 5]) != b"\xe9" + rel32(hook_a_va, cave):
            raise ValueError("hook A verification failed")
        if bytes(c[loop : loop + 5]) != b"\xe9" + rel32(loop_va, cave + STUB_B_OFFSET):
            raise ValueError("hook B verification failed")
        if bytes(c[cave_off : cave_off + len(stub_a)]) != stub_a:
            raise ValueError("stub A verification failed")
        if bytes(c[cave_off + STUB_B_OFFSET : cave_off + STUB_B_OFFSET + len(stub_b)]) != stub_b:
            raise ValueError("stub B verification failed")

    verb = "would patch" if dry_run else "patched"
    print(
        f"{path}: {verb} damageRegionProcessPending "
        f"(hook A {hook_a_va:#x} -> {cave:#x}, hook B {loop_va:#x} -> "
        f"{cave + STUB_B_OFFSET:#x}, exit {exit_va:#x})"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as e:
        sys.exit(f"error: {e}")
