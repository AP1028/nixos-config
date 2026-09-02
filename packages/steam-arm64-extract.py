#!/usr/bin/env python3
"""Extract Valve's native arm64 Steam client zip.

The archive is produced on Windows and a handful of entries use backslash
path separators, which Info-ZIP ``unzip`` would keep literally (creating
files named e.g. ``steamrtarm64\libs\libcurl.so``). Python's ``zipfile``
normalises those to forward slashes and re-creates the archive's symlinks
(libcurl.so -> libcurl.so.4.8.0, ...), so we extract with it instead.
"""

import os
import sys
import zipfile


def main(src: str, out: str) -> None:
    with zipfile.ZipFile(src) as z:
        for zi in z.infolist():
            name = zi.filename.replace("\\", "/")
            dest = os.path.join(out, name)

            if name.endswith("/"):
                os.makedirs(dest, exist_ok=True)
                continue

            os.makedirs(os.path.dirname(dest), exist_ok=True)

            mode = (zi.external_attr >> 16) & 0o170000
            if mode == 0o120000:  # symlink
                target = z.read(zi).decode("utf-8")
                try:
                    os.symlink(target, dest)
                except FileExistsError:
                    pass
            else:
                with open(dest, "wb") as f:
                    f.write(z.read(zi))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
