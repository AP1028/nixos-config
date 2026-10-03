# KrKr2 Emulator on Linux — compatibility notes

Findings from packaging and testing the upstream `2468785842/krkr2` emulator
against a 17-title collection (2026-10, nixpkgs, x86_64-linux).

## Script formats the engine understands

`tTJSByteCodeLoader` / `tTJSBinarySerializer` accept exactly:

| Format | Magic | Handled |
|---|---|---|
| UTF-16 text (LE/BE, with BOM) | `ff fe` / `fe ff` | yes |
| UTF-8 text | (no BOM) | yes |
| TJS2 bytecode | `TJS2100\0` | yes |
| KiriKiri binary serializer | `KBAD100\0` | yes |
| TJS/ns0 · TJS/4s0 ("PackinOne") | `TJS/ns0\0` / `TJS/4s0\0` | **no** |

Anything else is fed to the TJS *parser* as text, which the parser rejects with
`syntax error`; the exception path then segfaults (see bugs below).

## Title compatibility

Tested with `bin/krkr2 <title>/data.xp3` (or the archive that owns
`startup.tjs`), 15 s per run, writable game root.

| Title | Result |
|---|---|
| 9 nine 1–5 | run (script reads 96–99) |
| LimeLight Lemonade Jam | run (146) |
| 天使纷扰 | run (146) |
| NOBLE☆WORKS | run (65) |
| 天神乱漫 | run (61) |
| 天色幻想岛 | run (89) |
| 魔女的夜宴 | run (91) |
| 夏空彼方 | exits early, 0 scripts — not yet diagnosed |
| DRACU-RIOT! | needs Windows plugin `plugin/dracuriot.tpm` |
| PARQUET | run (140) — was failing before the scrambled-script fix |
| Riddle Joker | run (120) — was failing before the scrambled-script fix |
| 千恋万花 | run (116) — was failing before the scrambled-script fix |
| 星光咖啡馆与死神之蝶 | run (128) — was failing before the scrambled-script fix |

Note: in the test sandbox the game directories are read-only, so titles that
save (`savedata/savecheck`) abort with `File Writing Error`. On a normal
machine the directories are writable and those runs continue.

## Backed out: save loading (frame flashing)

Three changes made while fixing save loading were reverted on request:

* `psbfile-mdf-signature.patch` — accepting lowercase `mdf\0` scenario
  containers. It made save loading succeed, but from the moment the save
  picker opened the window flashed continuously (also after the scene had
  loaded), on both the software-GL session and the user's GPU run.
* `transition-missing-handler-log.patch` — logging the unknown `wave`
  transition instead of showing the modal warning box.
* The PSB resource registration rework that went with them
  (`PSBMedia::removeByPrefix` + `registerPsbResources`, matching KrKr2-Next).

State after the revert: rendering is stable again, and loading a save fails
with `Not a valid PSB file` (kagenvplayer.tjs → initStorage → `PSBFile` on a
`scn/*.ks.scn`), exactly as before. The current best explanation is that the
engine's rendering of the transition into the save picker is what breaks, and
it only became visible once the scene data could actually be loaded; that needs
investigating before the MDF fix can come back.

## The `Storages.tjs` failure (fixed)

The four titles above ship **Kirikiri-scrambled** scripts: the file starts with
`FE FE <mode> FF FE` (magic, scrambling mode, UTF-16LE BOM) and the payload is
bit-scrambled UTF-16. The loader skipped only 4 header bytes, so every code
unit was shifted by one byte and the TJS parser saw garbage:

```
FE FE 01 FF FE | 1F 00 15 00 0E 00 05 ...     raw storage
                 -> mode 1 bit de-interleave ->
                 2F 00 2A 00 0D 00 0A ...     "/*\r\n" (valid TJS)
```

`patches/kirikiri-scrambled-script.patch` fixes the header skip (3 bytes, or 5
when a BOM follows) and keeps the existing mode 0/1/2 handling. Reference:
<https://github.com/arcusmaximus/KirikiriTools> (`KirikiriDescrambler`).
No key material is involved — these files were never encrypted, only
scrambled, and the games' own `xp3filter.tjs` XOR layer is decoded correctly.

`patches/psbfile-storage-media.patch` fixes a second crash that surfaced once
the scripts loaded: `psbfile`'s `load()` used a translation-unit-local
`PSBMedia *` that `initPSBMedia()` (in `PSBMediaRegistry.cpp`) never
initialised, so the first `new PSBFile(...).load("*.pimg")` died on a null
virtual call.

## Original analysis of the `Storages.tjs` failure

All four failing titles stop on the same script:

```
SCRIPTPROBE name=[Storages.tjs] place=[.../data.xp3>main/storages.tjs]
            hdr=fe fe 01 ff fe 1f 00 15
[tjs2] [critical] syntax error (block: storages.tjs) at line 1
```

Verification performed:

* The XP3 extraction filter is implemented correctly: for Riddle Joker the
  game's own `xp3filter.tjs`
  (`var k = h ^ 0xABCD9876; ... b.xor(0,l,(k&0xFF)?k:0xA5);`) is found, its
  script is executed, the decoder registers, and the engine passes
  `FileHash/Offset/Buffer/BufferSize/FileName` — the observed keystream
  (`0xD0` for byte 0, `0xF0` thereafter) matches the script exactly.
* The bytes after filtering still start with `fe fe 01 ff`, which is neither
  text nor `TJS2100` bytecode nor `KBAD100`: it is the `TJS/ns0`/`TJS/4s0`
  ("PackinOne") container, whose real header (`TJS/ns0\0`/`TJS/4s0\0` + seed +
  crypt + iv_len) is itself wrapped by the rip's filter layer.
* Reference implementation of the container (header, PackinOne type-byte
  checker, BLAKE2s-keyed ChaCha20, framed LZ4):
  <https://git.lifegpc.com/lifegpc/msg-tool/raw/branch/master/src/scripts/kirikiri/tjs_ns0.rs>
* Related tooling for cxdec/hxv4 protected resources:
  <https://github.com/hktkqj/cxdec-hxv4-static-analysis>

## Remaining (after the fixes)

The four titles now reach their boot sequence (e.g. 千恋万花 loads 116 scripts,
brings up the cocos UI and starts the motion/logo stage). The next gap is the
motion API: the game's `affinesourceimage.tjs` `loadImages` raises a TJS
exception, and DRACU-RIOT! still needs the Windows plugin `dracuriot.tpm`.
Runs also still abort when they try to save, because the test sandbox keeps the
game directories read-only (`File Writing Error: .../savedata/savecheck`).

## Upstream bugs worth reporting

1. An undecodable script (unknown container) reaches the TJS parser, and the
   exception printer faults in `tTJSVariantString::GetLength()` — the process
   dies with SIGSEGV instead of reporting the file.
2. `free(): invalid pointer` on exit (heap corruption during shutdown).
3. The fork omits `-fno-delete-null-pointer-checks` for `tjs2`; without it the
   engine segfaults in `tTJSVariantString::GetLength()` on the first script
   that touches a null string. (Carried as a local patch.)
