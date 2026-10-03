# Kirikiri SDL2 packaging notes

Packaged from the upstream CI builds (the `latest` prerelease tag), since
upstream publishes neither tagged releases with binaries nor a nixpkgs
package.

- `krkrsdl2-ubuntu.zip` (x86_64) / `krkrsdl2-ubuntu-arm64.zip` (aarch64),
  fetched as-is and patched with `autoPatchelfHook`.
- The upstream build statically links SDL2, FAudio, zlib, freetype, libpng and
  opus; `readelf -d` shows only `libstdc++`, `libm`, `libgcc_s` and `libc`.
- Caveat: the release tag is rolling. If upstream rebuilds it, the hashes in
  `krkrsdl2.nix` must be refreshed (or switch to a source build pinned at a
  commit: six submodules — krkrz, SDL, FAudio, zlib, simde, meson_toolchains).

## Verified

The engine works: it mounts XP3 archives, runs `startup.tjs` and executes game
scripts (tested headlessly on Xvfb with the 千恋万花 and 魔女的夜宴 folders).

## Why it cannot run this collection's rips

1. **No XP3 filter / scrambler support.** The binary contains no
   `setXP3ArchiveExtractionFilter`, `xp3filter` or scramble symbols, so the
   games' own `xp3filter.tjs` (Cxdec/cxdec-style entry decryption, used by
   天神乱漫, Riddle Joker, 夏空彼方, DRACU-RIOT!) is never applied. The engine
   reads the still-encrypted bytes and fails while decoding the script
   (`Cannot convert given narrow string to wide string`).
2. **Windows plugins are fatal.** For unprotected titles (e.g. 魔女的夜宴) the
   engine gets as far as `initialize.tjs` and then stops in its KiriKiri2
   compatibility layer:
   `k2compat.tjs(175) hookPluginLink -> Cannot load Plugin win32dialog.dll`.
   Upstream's answer to that is `krkrsdl2-tp_stub.tar.gz`, a template for
   *writing* plugin stubs — not ready-made shims.
3. `System.exePath` must contain the resolution archives (`data1080.xp3` etc.),
   i.e. the engine has to sit in the game folder, exactly like the original
   Windows exe.

Upstream states this explicitly: "Running unmodified commercial games using
this project is not supported. Please use Wine or GameNative instead."

For the rips in this collection the practical routes are therefore the
original Windows engine under Wine (or on Windows), or an engine that
implements the XP3 filter API.
