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
| PARQUET | `TJS/ns0·4s0` script container |
| Riddle Joker | `TJS/ns0·4s0` script container |
| 千恋万花 | `TJS/ns0·4s0` script container |
| 星光咖啡馆与死神之蝶 | `TJS/ns0·4s0` script container |

Note: in the test sandbox the game directories are read-only, so titles that
save (`savedata/savecheck`) abort with `File Writing Error`. On a normal
machine the directories are writable and those runs continue.

## The `Storages.tjs` failure

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

## Upstream bugs worth reporting

1. An undecodable script (unknown container) reaches the TJS parser, and the
   exception printer faults in `tTJSVariantString::GetLength()` — the process
   dies with SIGSEGV instead of reporting the file.
2. `free(): invalid pointer` on exit (heap corruption during shutdown).
3. The fork omits `-fno-delete-null-pointer-checks` for `tjs2`; without it the
   engine segfaults in `tTJSVariantString::GetLength()` on the first script
   that touches a null string. (Carried as a local patch.)
