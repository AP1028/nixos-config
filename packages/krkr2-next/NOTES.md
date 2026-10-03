# krkr2-next packaging notes

Flutter front end (`reAAAq/KrKr2-Next`) over a native engine, built from source
in `app.nix` / `engine.nix`. The engine carries these local patches:

- `engine-build-fixes.patch` — dependency/build fixes (nixpkgs instead of
  bundled vcpkg-style deps: uchardet, libunrar, FFmpeg 4, libhwy, …) plus the
  Kirikiri *scrambled script* support and tolerant motion stubs.
- `screen-size-fix.patch`, `frame-readback-fix.patch` — the rendering fixes
  below.
- `font-default-regular.patch` — font selection fixes (see "Text rendering").
- `addfont-plugin.patch` — an internal `addFont.dll`, so games that register
  the fonts they ship inside their own archives can do so here too.

## Rendering fixes (verified)

Both were found by running the engine headlessly: a small dlopen harness drives
`engine_create` → `engine_open_game` → `engine_tick`, injects input through
`engine_send_input` and dumps frames via `engine_get_frame_desc` /
`engine_read_frame_rgba`, so frames can be inspected without a window.

1. **Virtual screen size** (`tTVPScreen::GetWidth()` returned a hardcoded 2048
   while the EGL surface stayed at the bridge default 1280x720). Games laid
   their layers out for a 2048-wide screen while the viewport covered only part
   of it. Both dimensions now come from the actual EGL surface.
2. **Frame grab** used the *current* GL viewport and whatever framebuffer the
   renderer had left bound. Once the game created its power-of-two layer
   textures, that was a 2048x2048 layer texture instead of the composed screen —
   which is why the UI appeared shifted and mirrored and backgrounds were
   missing. The grab now binds the default framebuffer, sets a surface-sized
   viewport, reads, and restores the previous binding.

Before/after: frames came back as a 2048x2048 layer texture holding a mirrored
duplicate of the UI; now they are 1280x720 and the game renders correctly —
caution screen, title menu and playable scenes (verified "CHAPTER 1-1" scene
with its background art) with no mirroring.

## Text rendering (verified)

Text came out hairline/hollow — Thin-weight glyphs with the background showing
through the strokes — and the fallback font also changed glyph shapes and
advances compared with the face the game asks for (this title requests
`微软雅黑`, which is not installed).

Two causes, both confirmed with a controlled test project that draws a fixed
string on a white layer (run with the engine's own `layer.drawText`, so scene
text styling cannot confuse the comparison):

1. **Thin/ExtraLight faces won the name lookup.** `TVPInternalEnumFonts()`
   stored the *SFNT name-record index* as `TVPFontNamePathInfo::Index` for
   localized (CJK) family names, but that field is the *face* index passed to
   `FT_New_Memory_Face`/`OpenFaceByIndex`. Fonts whose names come from those
   entries therefore opened an arbitrary face of a collection — in practice a
   Thin/ExtraLight instance. Fixed to store the face index; the default face is
   also now chosen from a Regular-style face instead of "last name registered".
2. **The bundled font itself was a variable font.**
   `NotoSansCJK-VF.otf.ttc` renders in its default Thin instance because the
   engine does not set variation axes, and `SourceHanSans.ttc` starts at
   ExtraLight. `app.nix` now bundles **WenQuanYi Micro Hei**, which is a single
   static Regular face covering Chinese, Japanese kana and Korean; a test
   project renders solid, correctly weighted text with it.

Games that ship their own fonts (`font/MTLc3m.ttf`, `font/SourceHanSansJP-*.otf`
in this title) register them through the Windows-only `addFont.dll`; the new
internal plugin accepts its exported `AddTrueTypeFont()` calls and registers the
referenced files through the storage layer (verified: `addFont: registered 1
face(s) from [font/MTLc3m.ttf]`).

## Known remaining gap

The **title screen's own art is black**. Its `title_bg`/event objects are drawn
through `Motion.D3DAdaptor`, and this fork only provides a stub for that class
(`cpp/plugins/motionplayer/main.cpp`): `captureCanvas` stores the canvas but the
draw/`copyRect`/`drawLayer` calls, `mainImageBuffer`, `width`/`height` and the
rest are answered with zeroes, so nothing is composited. The motion player
itself does load and evaluate `*.mtn` motions (they appear in the log), so the
missing piece is the D3D canvas compositing path, i.e. a real implementation of
that adapter — a sizable feature, not a small fix. Static image layers work.

## Installation

`hosts/asusg16/packages/default.nix` installs it (the macbook stays without it).
Note `libunrar` is unfree and needs `allowUnfree`, which both hosts set.
