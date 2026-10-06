#!/usr/bin/env python3
"""Rename KiriKiri2 game directories to lowercase, for Kirikiroid2 on Waydroid.

Kirikiroid2's engine lowercases the paths it opens (a Windows-era habit: it
builds `file://./storage/emulated/0/...` for the archive it is about to read).
Android's emulated storage is case-sensitive, so a game in

    /sdcard/krkr2/[KR] 9 nine 1.九次九日九重色/data.xp3

fails with

    Cannot open storage file://./storage/emulated/0/krkr2/[kr] 9 nine 1.../data.xp3

which the engine reports as an uncaught `TJS::eTJSError` -- the app dies with
SIGABRT the moment you tap `data.xp3` (or `krkr.exe`).  Renaming the directory
so every character is already lowercase makes the open succeed and the game
starts.

Usage:
  fix-krkr2-lowercase.py /sdcard/krkr2            # dry run (default)
  fix-krkr2-lowercase.py --apply /sdcard/krkr2
  fix-krkr2-lowercase.py --apply --recursive /sdcard/krkr2

Run it inside the container (`waydroid shell`) or on the host against the
mounted image; the rename is a same-filesystem rename, so it is instant even
for a 30 GB library.  Re-running is a no-op.
"""

import argparse
import os
import sys


def lower(path):
    return path.lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", help="directory whose entries should be lowercased")
    ap.add_argument("--apply", action="store_true", help="actually rename (default: dry run)")
    ap.add_argument("--recursive", action="store_true",
                    help="also lowercase nested entries (not needed for the archive-open fix)")
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        print(f"{args.root}: not a directory", file=sys.stderr)
        return 2

    # Walk deepest-first so renaming a parent does not invalidate child paths.
    entries = []
    for dirpath, dirnames, filenames in os.walk(args.root, topdown=False):
        if dirpath == args.root and not args.recursive:
            names = dirnames + filenames
        elif not args.recursive:
            continue
        else:
            names = dirnames + filenames
        for name in names:
            if name != lower(name):
                entries.append(os.path.join(dirpath, name))

    if not entries:
        print(f"{args.root}: nothing to rename")
        return 0

    for path in entries:
        target = os.path.join(os.path.dirname(path), lower(os.path.basename(path)))
        if os.path.exists(target):
            print(f"SKIP  {path}  ({target} already exists)")
            continue
        print(f"{'rename' if args.apply else 'would rename'}  {os.path.basename(path)} -> {os.path.basename(target)}")
        if args.apply:
            os.rename(path, target)

    if not args.apply:
        print("\nRe-run with --apply to rename.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
