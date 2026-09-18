#!/usr/bin/env python3
"""Populate a FEX rootfs's multiarch library directories from a store closure.

pressure-vessel expects the graphics provider to be a complete multiarch
userland — SteamOS's guestos/fex-mesa rootfs is a full distro tree, not a
curated set of libraries — and it only wires provider libraries into the game
container for architectures the provider covers. Missing entries surface much
later as unrelated-looking failures (libz for a helper, libdrm for mesa's
driver dlopen), so copy the whole closure instead of guessing.

Libraries are sorted by ELF e_machine rather than by package, and names that
resolve to the same file become relative symlinks so shared objects are not
duplicated.
"""

import os
import shutil
import struct
import sys

ARCH = {0x3E: "x86_64-linux-gnu", 0xB7: "aarch64-linux-gnu"}

# lib dirs to harvest from each store path, and the subdirectory in the target
# tree they belong to (mesa's DRI modules and gbm modules live under dri/).
SOURCES = (
    ("lib", ""),
    ("lib64", ""),
    ("lib/dri", "dri"),
    ("lib/gbm", "dri"),
)


def elf_arch(path):
    """Return the multiarch tuple for an ELF file, or None."""
    try:
        with open(path, "rb") as handle:
            header = handle.read(20)
    except OSError:
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return None
    return ARCH.get(struct.unpack_from("<H", header, 18)[0])


def main():
    store_paths_file, rootfs = sys.argv[1], sys.argv[2]
    # Library root inside the target tree: "usr/lib" (FEX rootfs) or "lib"
    # (FHS sandbox rootfs, whose /usr/lib is owned by its builder).
    libroot = sys.argv[3] if len(sys.argv) > 3 else "usr/lib"
    written = set()  # dst paths already written
    copied = {}  # realpath -> path it was written to

    def dest_dir(arch, subdir):
        path = os.path.join(rootfs, libroot, arch, subdir)
        os.makedirs(path, exist_ok=True)
        return path

    with open(store_paths_file) as handle:
        roots = [line.strip() for line in handle if line.strip()]

    skipped = 0
    seen_dirs = set()
    for root in roots:
        for rel, subdir in SOURCES:
            srcdir = os.path.join(root, rel)
            if not os.path.isdir(srcdir):
                continue
            # Skip duplicate dirs: nix packages often alias lib64 -> lib, and
            # harvesting both passes would unlink each real copy on the second
            # pass and replace it with a symlink pointing to itself.
            rp = os.path.realpath(srcdir)
            if rp in seen_dirs:
                continue
            seen_dirs.add(rp)
            for name in sorted(os.listdir(srcdir)):
                src = os.path.join(srcdir, name)
                if not os.path.isfile(src):  # follows links; skips directories
                    continue
                arch = elf_arch(src)
                if arch is None:  # static archives, linker scripts, ...
                    continue
                real = os.path.realpath(src)
                destdir = dest_dir(arch, subdir)
                dst = os.path.join(destdir, name)
                # Always write REAL files, never alias symlinks: a self-
                # referencing alias reads as dangling and silently removes the
                # library from the provider (this bit us with glibc's
                # lib64 -> lib double harvest).
                if dst in written:
                    continue
                written.add(dst)
                try:
                    shutil.copy2(real, dst)
                except OSError as err:
                    print(f"skip {src}: {err}", file=sys.stderr)
                    skipped += 1
                    continue
                copied[real] = dst

    print(f"copied {len(copied)} libraries, skipped {skipped}")


if __name__ == "__main__":
    main()
