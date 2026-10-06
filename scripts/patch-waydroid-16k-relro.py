#!/usr/bin/env python3
"""Make 4 KiB-linked Android native libraries survive a 16 KiB-page kernel.

The 16 KB page-size requirements people check are ELF segment alignment
(p_align >= 16 KB) and keeping uncompressed ``.so`` entries 16 KB-aligned
inside the APK.  There is a third one nobody checks: the *end* of
``PT_GNU_RELRO`` must be 16 KB-aligned too, because bionic rounds the RELRO
range up to the page size when it mprotects it read-only.

A library linked for 4 KiB pages has, say, RELRO ending at 0x122000.  On a
16 KiB kernel that rounds up to 0x124000, so the first 8 KiB of ``.data`` is
mapped read-only -- and the first store there dies with SIGSEGV/SEGV_ACCERR.
(SDL2 does exactly that: ``SDL_DYNAPI_entry`` memcpy()s its jump table into
``.data+0x70``, so SDL2-based apps crash ~200 ms after launch on 16 KiB
kernels.)

The fix is to rewrite ``PT_GNU_RELRO.p_memsz`` so the region ends on the
previous 16 KiB boundary: RELRO hardening keeps covering everything but its
tail and ``.data`` becomes writable again.

Usage -- prefer ``--emit``:

  # report only (exit 1 if something would be patched)
  patch-waydroid-16k-relro.py ~/.local/share/waydroid/data/app/*/*/base.apk

  # deploy: write 16 KiB-safe copies of the affected libraries into the app's
  # own lib dir, which the linker searches *before* the APK.  Stale copies of
  # libraries that no longer need fixing are removed, so re-running is safe.
  patch-waydroid-16k-relro.py --emit <app>/lib/arm64 <base.apk>

  # one-off: patch a *copy* of an APK (see the warning below)
  cp app.apk app-patched.apk && patch-waydroid-16k-relro.py --apply app-patched.apk

Why ``--emit`` instead of patching the APK in place: Android verifies APK
signatures again when PackageManager re-scans packages at boot, so an APK
patched after the fact is dropped -- the package disappears and its directory
is deleted ("Package ... not installed").  Writing the library into the app's
lib dir leaves the APK (and therefore its signature) untouched, and the app's
linker namespace searches that directory first (``library_path`` starts with
``/data/app/<pkg>/lib/<abi>``), so the fixed copy is the one that gets mapped.
Re-run it after updating the app: a new install brings a fresh, empty lib dir.
"""

import argparse
import os
import shutil
import struct
import sys
import zipfile
import zlib

PT_GNU_RELRO = 0x6474E552
PAGE = 16384

# Android's nativeLibraryDir ABI names vs the APK's lib/<abi>/ entry names.
ABI_DIRS = {
    "arm64": "arm64-v8a",
    "arm": "armeabi-v7a",
    "x86_64": "x86_64",
    "x86": "x86",
}


def apk_abi_dir(libdir_name):
    """Map a lib dir name ('arm64', 'arm64-v8a', ...) to the APK's lib/<abi>."""
    if libdir_name in ABI_DIRS:
        return ABI_DIRS[libdir_name]
    if libdir_name in ABI_DIRS.values():
        return libdir_name
    return None


def elf_relro(data, doff):
    """Return (phdr offset, vaddr, memsz, memsz field offset, fmt) or None.

    Handles both ELF classes: an APK routinely carries 32-bit and 64-bit copies
    of the same library.
    """
    elfclass = data[doff + 4]
    if elfclass == 2:                            # ELFCLASS64
        e_phoff, = struct.unpack_from("<Q", data, doff + 0x20)
        e_phentsize, = struct.unpack_from("<H", data, doff + 0x36)
        e_phnum, = struct.unpack_from("<H", data, doff + 0x38)
        vaddr_off, memsz_off, fmt = 16, 40, "<Q"
    elif elfclass == 1:                          # ELFCLASS32
        e_phoff, = struct.unpack_from("<I", data, doff + 0x1C)
        e_phentsize, = struct.unpack_from("<H", data, doff + 0x2A)
        e_phnum, = struct.unpack_from("<H", data, doff + 0x2C)
        vaddr_off, memsz_off, fmt = 8, 20, "<I"
    else:
        return None

    for i in range(e_phnum):
        off = doff + e_phoff + i * e_phentsize
        if off + e_phentsize > len(data):
            return None
        if struct.unpack_from("<I", data, off)[0] == PT_GNU_RELRO:
            vaddr, = struct.unpack_from(fmt, data, off + vaddr_off)
            memsz, = struct.unpack_from(fmt, data, off + memsz_off)
            return off, vaddr, memsz, memsz_off, fmt
    return None


def entry_data_offset(data, zi):
    name_len, extra_len = struct.unpack_from("<HH", data, zi.header_offset + 26)
    return zi.header_offset + 30 + name_len + extra_len


def central_record(data, name):
    needle = b"PK\x01\x02"
    cd = data.find(needle)
    while cd != -1:
        n, = struct.unpack_from("<H", data, cd + 28)
        if bytes(data[cd + 46:cd + 46 + n]) == name:
            return cd
        cd = data.find(needle, cd + 4)
    return None


def patched_library(data, zi):
    """Return 16 KiB-safe bytes for entry `zi`, or None if it needs no fix."""
    if zi.compress_type != zipfile.ZIP_STORED:
        return None
    doff = entry_data_offset(data, zi)
    if data[doff:doff + 4] != b"\x7fELF":
        return None
    found = elf_relro(data, doff)
    if not found:
        return None
    off, vaddr, memsz, memsz_off, fmt = found
    end = vaddr + memsz
    if end % PAGE == 0:
        return None
    lib = bytearray(data[doff:doff + zi.file_size])
    struct.pack_into(fmt, lib, off - doff + memsz_off, (end // PAGE) * PAGE - vaddr)
    return bytes(lib)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("apks", nargs="+")
    ap.add_argument("--apply", action="store_true",
                    help="patch the APK in place (breaks its signature; see --emit)")
    ap.add_argument("--emit", metavar="LIBDIR",
                    help="write fixed copies of the affected libraries into this app lib dir")
    args = ap.parse_args()

    if args.apply and args.emit:
        ap.error("--apply and --emit are mutually exclusive")

    abi = None
    if args.emit:
        abi = apk_abi_dir(os.path.basename(os.path.normpath(args.emit)))
        if abi is None:
            ap.error(f"--emit: cannot tell the ABI from {args.emit!r} "
                     f"(expected a directory named one of: {', '.join(ABI_DIRS)})")
        if not os.path.isdir(args.emit):
            ap.error(f"--emit: {args.emit} is not a directory")

    needs_fix = False
    emitted = 0
    for apk in args.apks:
        try:
            with zipfile.ZipFile(apk) as z:
                infos = [i for i in z.infolist()
                         if i.filename.startswith("lib/") and i.filename.endswith(".so")]
        except (OSError, zipfile.BadZipFile) as e:
            print(f"{apk}: not readable ({e})", file=sys.stderr)
            continue

        print(f"{apk}")
        if not infos:
            print("  (no bundled native libraries)")
            continue

        data = bytearray(open(apk, "rb").read())
        changed = False
        for zi in infos:
            if zi.compress_type != zipfile.ZIP_STORED:
                print(f"  skip  {zi.filename}: compressed entry (cannot know page alignment)")
                continue
            doff = entry_data_offset(data, zi)
            if data[doff:doff + 4] != b"\x7fELF":
                print(f"  skip  {zi.filename}: not an ELF")
                continue
            found = elf_relro(data, doff)
            if not found:
                print(f"  ok    {zi.filename}: no PT_GNU_RELRO")
                continue
            off, vaddr, memsz, memsz_off, fmt = found
            end = vaddr + memsz
            aligned = (end // PAGE) * PAGE
            broken = end % PAGE != 0
            if broken:
                print(f"  NEEDS {zi.filename}: RELRO end {end:#x} -> {aligned:#x} "
                      f"({(end - aligned) / 1024:.1f} KiB of .data is read-only on this kernel)")
                needs_fix = True
            else:
                print(f"  ok    {zi.filename}: RELRO end {end:#x} is 16 KiB aligned")

            if args.emit:
                if not zi.filename.startswith(f"lib/{abi}/"):
                    continue
                dest = os.path.join(args.emit, os.path.basename(zi.filename))
                if broken:
                    with open(dest, "wb") as f:
                        f.write(patched_library(data, zi))
                    print(f"  wrote {dest}")
                    emitted += 1
                elif os.path.exists(dest) and not os.path.islink(dest):
                    os.unlink(dest)
                    print(f"  removed stale {dest}")
            elif args.apply and broken:
                struct.pack_into(fmt, data, off + memsz_off, aligned - vaddr)
                crc = zlib.crc32(data[doff:doff + zi.file_size]) & 0xFFFFFFFF
                struct.pack_into("<I", data, zi.header_offset + 14, crc)
                cd = central_record(data, zi.filename.encode())
                if cd is None:
                    raise SystemExit(f"{apk}: central directory record for {zi.filename} not found")
                struct.pack_into("<I", data, cd + 16, crc)
                changed = True

        if changed:
            backup = apk + ".orig-4k-relro"
            if not os.path.exists(backup):
                shutil.copy2(apk, backup)
                print(f"  backup: {backup}")
            with open(apk, "wb") as f:
                f.write(data)
            print("  patched (signature now stale -- PackageManager will drop this package)")

    if args.emit:
        print(f"\nemitted {emitted} libraries into {args.emit}")
    elif needs_fix and not args.apply:
        print("\nRe-run with --emit <app lib dir> to deploy, or --apply to patch the APK.")
    return 1 if (needs_fix and not (args.apply or args.emit)) else 0


if __name__ == "__main__":
    sys.exit(main())
