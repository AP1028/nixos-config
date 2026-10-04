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

## Motion / title art (in progress)

The title screen's art comes from PSB motions (`title_bg.mtn`, `yuzulogo.mtn`,
`m2logo.mtn`) driven through Yuzusoft's affine layer system. Several concrete
gaps were found from the engine's own logs rather than by guessing:

* The game asks for **`motionplayer_nod3d.dll`** (the non-Direct3D motion
  player) and, when it is missing, falls back to the `Motion.D3DAdaptor` path.
  This runtime's motion player *is* the non-D3D implementation, so
  `motionplayer-nod3d.patch` routes that name (and `emoteplayer*.dll`) to it,
  matching by file name so full plugin paths work too.
* `Motion.D3DAdaptor` answered `mainImageBuffer`, `mainImageBufferPitch`,
  `width`, `height`, `canvasCaptureEnabled` … with zeroes. It now forwards them
  to the layer passed to `captureCanvas()` (verified in the log: the game reads
  `width -> 1920`, `height -> 1080`) and forwards the drawing calls, answering
  harmlessly when the canvas does not implement one — a hard error there turned
  into a script exception inside the game's `affinelayer.tjs / drawAffine`.
* PSB layer positions are **centre-relative** (a full-screen 1920x1080 layer is
  at `-960,-540`, the logo at `-923,-480`), but the compositor used them as
  top-left coordinates, so everything was drawn off-screen. It now shifts by
  half the composition size (`drawPSBImages: centre offset 960/540`) and
  re-composites on every draw instead of once, since the game repaints its work
  layer each frame.
* `TVPShowSimpleMessageBox` aborted the process when GTK could not start (no
  display); it now logs and returns, so a script error can no longer take the
  whole app down. `messagebox-headless.patch`.

Progress on that path:

* `Layer.loadImages` raised for images the original multi-image plugin would
  have resolved (the game asks for names such as `blandlogo1.png`, which do not
  exist in the release). It now logs and leaves the layer untouched, which
  removed the last script exception: the run no longer throws at all.
* The tree's **`layerExDraw`** plugin is the `layerExDraw.dll` the game asks
  for. It sits behind the unset `KRKR_ENABLE_LAYEREX_DRAW` option, is absent
  from the plugin link list, and its cross-platform sources did not compile
  against libgdiplus (ambiguous encoder GUIDs/constants, an `int*`/`UINT*`
  mismatch, and the internal `gdip_get_display_dpi` symbol that the shared
  library does not export). All of that is fixed and the option is enabled, so
  the log now reports `Loading Plugin: layerExDraw.dll Success`.

The title art still does not appear: the game reaches its title menu and stays
there with no background art.

Still failing: the game's own `affinesourceimage.tjs(loadImages)` used to throw
(`VM ip = 666`) whenever the affine layer is set up, which aborts the title art
compositing. The same exception is present in every run, including those before
these changes, so it is a pre-existing gap rather than a regression. Next step
is to trace that function's calls (it is compiled bytecode) and provide the
missing plugin surface — likely `LayerExDraw`/`perspective`, which this tree
keeps behind the unset `KRKR_ENABLE_LAYEREX_DRAW` CMake option while
`layerExRaster`, `layerExImage` and `layerExMovie` are already compiled in.

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
