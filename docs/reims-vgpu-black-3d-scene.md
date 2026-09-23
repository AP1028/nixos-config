# Reims vGPU: the black 3D scene — defects, evidence, fixes, and open work

Status: **scene renders; a set of defects fixed and booted; performance and a
few artifacts remain open.** This document is the investigation record and the
basis for the upstream report. Patches are in `packages/reims-vgpu/`; the two
that touch the vendored translator are in the same directory and applied in
`default.nix`.

Environment and reproduction commands are at the end. Every claim below names
the counter, log line, or code path it came from, so a reader can re-derive it
without this document.

---

## 1. Symptom and progression

Driving a 3D Unity title (`Easy Red 2`, and `Universe Sandbox` / `Star Birds`)
on a macOS 13.7.8 x86 guest with `reims-vgpu-pci` on the Vulkan rail:

1. First observed: the game window was **completely black** while the menu bar
   and the desktop rendered.
2. After the first fixes: **2D UI rendered; all 3D content absent** (the menu
   background, the terrain, the vehicles).
3. After the render-target-format fixes: the **scene rendered** (sky, terrain,
   eventually a tank), but with a flat depth-driven "fog", pink patches, missing
   objects, stale-frame artifacts, and eventually seconds-to-minutes-per-frame
   stalls.
4. `Star Birds` remains completely black and is **not yet diagnosed** (see §7).

The investigation used two device logs, both written by the QEMU device on the
host:

- `/tmp/reims-vgpu-fail.log` — the always-on fail channel: refusals, latched
  diagnostics, per-second censuses.
- `/tmp/reims-vgpu-draw.log` — verbose (`REIMS_VGPU_DRAW_LOG=on`): per-draw
  resource/preparation lines, phase census, per-draw outcomes.

Boot with `REIMS_VGPU_LAZY_WRITEBACK=off REIMS_VGPU_DRAW_LOG=on` (the helper
`/tmp/opencode/run-game.sh <qemu-bin> <tag>` does this, shuts the previous guest
down cleanly over SSH first, and waits for SSH).

---

## 2. Defects

Each defect is one `## 2.x` entry: symptom → evidence → cause → fix → status.
`Fix` names the patch file; `kind` is one of **bug** (the device refused or lost
work that should have worked), **design** (a heuristic or identity decision a
maintainer should own), or **diagnostic** (temporary instrumentation).

### 2.1 `MTLStoreActionUnknown` dropped 84 % of a Unity title's exec packets — bug

**Symptom.** Every render packet of the game was refused at the ordering plane;
the window stayed at its black clear while music and the desktop ran.

**Evidence.** The fail log at ~2 600 refusals/s against ~2 900 packets/s
loaded:

```
resolve_field_ordinal_undefined field="store_action" value: 4
```

**Cause.** Unity encodes render passes with `MTLStoreActionUnknown` (the SDK's
deferred form) and replaces it with `SetStoreAction` records before the encoder
ends. The model's descriptor resolver refused the ordinal `4`, which refused the
whole exec packet at the ordering plane.

**Fix.** `pr-store-action-deferred.patch` (kind: bug). Adds
`MTL_STORE_ACTION_UNKNOWN = 4` to `reims-vgpu-protocol/src/pass_action.rs`,
parses `4` as `Store` in `reims-vgpu-core/src/pass.rs`, and applies each
stream's `SetStoreAction` overrides to the arena descriptor in
`reims-vgpu-core/src/resolve.rs`.

**Status.** Refusal counter 0 on a driven boot; core tests pass.

### 2.2 `air.base_vertex` / `air.base_instance` had no lowering — bug

**Symptom.** After 2.1, the UI rendered but **no 3D**: every scene pipeline's
draws were refused before execution.

**Evidence.** 27 708 refusals of the shape:

```
linux_m2v_draw reason=draw_prepare_vertex_translate pipeline_ref=… \
  m2v_reason=m2v_vertex_translate stage=vertex \
  detail=entry_parameter_2_declares_AIR_role_'air.base_vertex',_which_has_no_lowering; \
  emitting_the_module_would_silently_read_a_zero_in_its_place
```

Every refused draw had `vtx=3 inst=1 prim=3 first=0 idx=0` — Unity's scene
pipelines declare the base parameters on all vertex shaders and draw with
non-indexed, base-zero geometry.

**Cause.** metal2vulkan's metadata knows `vertex_id`/`instance_id` but not
`base_vertex`/`base_instance`. Metal's base parameters are exactly the values
Vulkan's `VertexIndex`/`InstanceIndex` **fold in**, so they cannot be recovered
from those builtins and need `BaseVertex`/`BaseInstance`.

**Fix.**
- `metal2vulkan-base-vertex.patch` (kind: bug): adds the two roles to
  `VERTEX_INPUT_ROLES`, `VertRole::BaseVertex/BaseInstance`, and lowers them to
  `BuiltIn::BaseVertex/BaseInstance` with the `DrawParameters` capability and
  `SPV_KHR_shader_draw_parameters` (the vendored translator; applied to
  `$TMPDIR/cargo-vendor/metal2vulkan-0.1.0`). Includes a unit test that reads
  the base through the body.
- `pr-shader-draw-parameters.patch` (kind: bug): adds `shader_draw_parameters`
  to the engine's `DeviceFeatures` (`VkPhysicalDeviceShaderDrawParametersFeatures`,
  queried via its own promoted struct because the 1.1 aggregate cannot be
  chained beside the device's 16-bit-storage struct) and chains it only when the
  host reports it.

**Status.** Refusals 0; UI-only → scene renders.

### 2.3 `[[front_facing]]` declared as an integer refused whole pipelines — bug

**Symptom.** Some 3D objects (vehicles) were missing after 2.2 while terrain
rendered.

**Evidence.**

```
linux_m2v_draw reason=draw_prepare_fragment_translate pipeline_ref=365 \
  m2v_reason=m2v_fragment_translate stage=fragment \
  detail=[[front_facing]]_parameter_17_is_not_a_bool; FrontFacing_is_a_boolean_builtin…
linux_clear_store draws_skipped … pipe=365 … vtx=645 … refused_by=draw_prepare_fragment_translate
```

`vtx=645` is real geometry, not a full-screen quad.

**Cause.** Unity's HLSL lowers some boolean uses to `i32`, and the shader
declares `[[front_facing]]` at that width. The stage-input pass accepted only a
bool parameter and refused the module.

**Fix.** `metal2vulkan-front-facing-int.patch` (kind: bug): an integer
parameter now lowers by loading the `FrontFacing` bool builtin and emitting
`OpSelect` into the parameter's own type (`ParamBinding::LoadBoolSelect`), which
is the conversion Metal performs. Includes a unit test.

**Status.** The vehicle appears during loading on a driven boot.

### 2.4 The game's render-target formats were not admitted — bug

**Symptom.** The scene colour target was never rendered, so the composite
sampled black; later, pink/wrongly lit terrain (the normal buffer).

**Evidence.** Repeated

```
rt_resolve reason=rt_linear_format base=… fmt=0x5c task=8 ref=…   (RG11B10Float)
rt_resolve reason=rt_linear_format base=… fmt=0x5a task=8 ref=…   (RGB10A2Unorm)
rt_resolve reason=rt_linear_format base=… fmt=0x14 task=8 ref=…   (R16Unorm)
rt_resolve reason=rt_linear_format base=… fmt=0x48 task=8 ref=…   (RGBA8Snorm)
```

**Cause.** `render_target_numeric_type` (the render-target admission set in
`reims-vgpu-protocol/src/pixel_format.rs`) lacked all four, so a pass naming one
as an attachment was refused at the linear-format rung of
`runtime/draw/render_target.rs`.

**Fix.** `pr-render-target-formats.patch` (kind: bug): admits all four with the
full set each admitted format must satisfy — numeric class, `bytes_per_pixel`,
`store_texel_order` (byte-copy destination), `is_render_target_layout`, a
`SampledClass` for the cross-check, the sampled/linear format maps, CPU
narrow/expand/row arms, the compute sampled-image class (for `RGBA8Snorm`), and
the tests' expected tables. Every Vulkan spelling is the guest's own word, so
the resident is a byte copy; only the CPU seed/readback conversions are new.

**Status.** `rt_linear_format` 0 for these formats; the scene renders.

### 2.5 MSAA store/resolve actions refused whole passes — bug

**Symptom.** Missing geometry (another class), especially before 2.4 was fixed.

**Evidence.**

```
linux_m2v_draw reason=multisample_store_action_unsupported … store=0x3 … vtx=600
linux_m2v_draw reason=multisample_load_action_unsupported … load=0x1 …
```

`0x3` is `MTLStoreActionStoreAndMultisampleResolve`; the pass resolves at end.

**Cause.** `runtime/draw/vulkan.rs` accepted only resolve-only (`0x2`) and
refused `LOAD` on a multisample source unconditionally.

**Fix.** `pr-msaa-store-and-resolve.patch` (kind: bug): accepts
`StoreAndMultisampleResolve` (the multisample image is device scratch here — no
rail writes one back to guest pages and Metal forbids sampling it — so the
resolve is the whole observable effect), and permits `LOAD` when the record
*continues* an open render pass, where the engine's single multisample-target
slot still holds what the previous record wrote.

### 2.6 Sampled depth had no reachable resident — bug (+ two design patches)

**Symptom.** All depth-sampling passes — the scene's post/composite chain —
were refused; the window showed UI over a black scene.

**Evidence.**

- `draw_prepare_texture_resolve_missing stage=fragment … fmt=0x104 / 0xfa …
  reason=linear_sample` on the scene's full-screen passes.
- Probing both sides showed the render side keys depth residents by a
  **texture reference** (`TargetIdentity::Texture { ref, w, h, generation: 0,
  stencil }`, from `depth_chain_identity`) while the sampled rails only built
  **GVA** identities, whose witness has no entry for a span no Store published
  (`Wrote(gvaw_no_entry)`).
- `depth_resident=5:46:4` (created : reused : freed) against
  `depth_sample_neutralized=186/s`.

**Cause.** A depth attachment is the one target kind whose content has no CPU
copy anywhere: its bytes exist only in the device resident, and the sampled
linear rails have no sampled layout for a depth format. The texture-keyed
resident was never consulted.

**Fix.**
- `pr-depth-resident-sample.patch` (kind: bug): `try_texture_resident_sample`
  builds the same `TargetIdentity::Texture` the render side used (both stencil
  spellings, format's aspect first) and binds the resident directly; and
  `reims-vgpu-vulkan::pixel::sample_view_format` takes the **resident's own
  format and aspects** for a depth image (the bind's spelling may name another
  depth precision — the device renders depth as `D32_SFLOAT` or its queried
  combined format — and a view in that spelling over the image would be a
  validation error).
- `pr-depth-resident-latest.patch` (**kind: design**): the guest ping-pongs or
  re-slots its camera depth, so a bind's own identity often finds no resident
  even though the frame the device just rendered is the content asked for. This
  serves the most recent ready depth resident of the same geometry, excluding
  the draw's own depth reference — serving that is a feedback read, which the
  engine answers with a full-image attachment snapshot per draw (a measured GPU
  and CPU cliff).
- `pr-depth-neutral-fallback.patch` (**kind: design**): a depth sample no rail
  can serve is a composite pass whose whole purpose is to put the 3D layer on
  screen; refusing it loses the frame. Serves a 1×1 neutral reading **far**
  (the value the guest's own clear left) and keeps the loss on the fail channel.

**Status.** `depth_sample_neutralized` drops as the resident rails take over;
scene renders. The identity model for ping-pong depth is the open question in
§7.

### 2.7 A GVA chain target armed no writeback debt — bug

**Symptom.** A later pass sampling the game's own render target gathered pages
nothing ever wrote and composited the clear (black).

**Evidence.** `wbdebt_texture_owes_nothing_unresolved=1 717/s`; sampled refs
resolved `route=guest_runs` with `mid=0`; the chain arm's only debt call was
mapping-keyed and refuses `mid=0`.

**Cause.** `M2vDrawSpan::ResidentChain` armed
`arm_surface_writeback_debt(mapping_id, …)`, which is mapping-keyed; a GVA
target (`mid=0`) therefore armed nothing, so the sampled rail's witness had no
entry.

**Fix.** `pr-chain-gva-writeback-debt.patch` (kind: bug): for a GVA target,
arms the same ledger the eager GVA Store arm uses (`arm_gva`), making the
resident authoritative (`chain_gva_debt_armed`).

### 2.8 Cross-task allocation identity — design

**Symptom.** A sampled ref could find no generation even though another
task's reference named the same guest allocation.

**Evidence.** Depth probe pairs render `ref 306` against sample `ref 308`
(adjacent), render `ref 90` against sample `ref 60`, in the same frame.

**Fix.** `pr-gva-debt-by-allocation.patch` (**kind: design**): when the bind's
own `(task, ref)` misses, `gva_debt_at` answers by allocation (newest matching
debt at the same GVA/width/height, tried under the bind's format then the
debt's). This is an identity-model decision the maintainer should own; it is
kept as a separate patch for that reason.

---

## 3. Performance: where the time actually goes

This is measured, not inferred. Take the numbers from `drain_duty`,
`draw_phase`, `chain_phase`, and `gpu_span` in `/tmp/reims-vgpu-draw.log`.

**The drain worker is the bottleneck, not PCIe or VRAM.**

```
drain_duty win_ms=4462 tranches=13 busy_us=4447630 duty=0.997
  draw_us=4170493 draws=1501              → 2.78 ms of drain work per draw
gpu_span busy_us=4184526 read=1054 draw_us=4147430 draw_n=1041
  store_us=0 readback_us=0 compute_us=37096
```

- `readback_us=0`, staging/upload counters negligible → **not** host↔GPU
  bandwidth; sharing VRAM with RAM is not the limiter.
- Desktop-only windows run `50–100 µs/draw`; the game's draws are **30–300×**
  that (14.4 ms/draw in one loading tranche).
- `chain_phase` for a game tranche: `sampled_us ≈ 1.87–1.91 s` over ~1 500
  chains → **~1.25 ms per draw in sampled-image resolution**, the dominant term
  after the ring wait.
- `draw_phase` splits the rest: `slot_us` (drain blocked on a ring fence)
  ≈ 0.62 ms/draw, `acquire_sampled_us` ≈ 0.30 ms/draw, `submit_us`
  ≈ 0.10 ms/draw.
- Example packet: 754 draws, `total_us=4657018`, `TRANSPORT
  reason=sync_exec_lock_hold threshold_us=250000`.

**Why resolution is expensive.** It is not a lookup. A game binds 30+ sampled
textures per draw over passes that share textures, and every bind re-runs the
rails: guest page-table walks over the texture's whole span (~3 500 pages for
1920×942 RGBA16F), guest-run window construction, packed-resource building,
writeback-debt payment, and host-cache re-reads with memcmp. `sampled_phase`
shows individual resolutions at 19–524 µs; 32 binds per draw lands on the
observed per-draw millisecond.

**An attempt that was withdrawn.** A per-`(task, ref)` memo of the resolved
source was implemented and then removed. Its validity gate (object-list
`descriptor_gva`/`object_type`, `buffer_write_gen` stamp, 250 ms age) covers
ref reuse and *declared* writes only; it cannot see guest CPU writes into
mapped texture pages, mapping remaps, writeback-debt content changes, or
resident reclaim. It served stale bytes (desktop/Steam artifacts) and dead
`Target` identities (refused draws), and **no test covered it**, so the green
suite was not evidence. Don't reintroduce a resolution cache without a witness
that covers every mutation class that can invalidate it.

**Sound direction (author's design call).** Cache the expensive *input* — the
page-table walk / packed GPA runs — not the resolved source, keyed by the
covering mapping's `MappingEntry::map_generation` (bumped on every write to a
page list, i.e. every map operation the device observes). Guest CPU stores to
mapped RAM do not change the walk, and a remap necessarily bumps the
generation. This is deliberately not implemented here; it is a caching-policy
decision in a component with an explicit currency vocabulary (`AGENTS.md`).

---

## 4. Patch inventory

Applied to `src` rev `69a57dd69a6958e946c03b73e02db331f330f435`
(`flake.nix` input `reims-vgpu`) unless noted. Patches earlier in this table
predate this investigation and are listed for completeness.

| Patch | Kind | Touches | What it repairs |
|---|---|---|---|
| `pr-store-action-deferred.patch` | bug | core, protocol | §2.1 deferred `store_action=4` |
| `metal2vulkan-base-vertex.patch` | bug | vendored translator | §2.2 base vertex/instance |
| `pr-shader-draw-parameters.patch` | bug | engine caps/context | §2.2 device feature |
| `metal2vulkan-front-facing-int.patch` | bug | vendored translator | §2.3 integer `[[front_facing]]` |
| `pr-render-target-formats.patch` | bug | protocol, vulkan, engine, compute | §2.4 four render targets |
| `pr-msaa-store-and-resolve.patch` | bug | runtime draw | §2.5 MSAA store/load actions |
| `pr-depth-resident-sample.patch` | bug | runtime draw, vulkan, engine | §2.6 depth resident bind |
| `pr-chain-gva-writeback-debt.patch` | bug | runtime draw | §2.7 chain GVA debt |
| `pr-depth-resident-latest.patch` | design | engine pools/mod, runtime draw | §2.6 ping-pong depth |
| `pr-depth-neutral-fallback.patch` | design | runtime draw | §2.6 absent depth |
| `pr-gva-debt-by-allocation.patch` | design | runtime draw, writeback debt | §2.8 allocation identity |
| `pr-diag-sampled-depth.patch` | diagnostic | engine exec, runtime draw | §6 probes (temporary) |
| `pr-diag-stamp-census.patch` | diagnostic | runtime drain | stamp census (temporary) |
| `pr81.patch`, `pr79.patch` | bug | — | earlier: format texel accounting, PR #79 |
| `pr-threadgroup.patch` | bug | — | `maxTotalThreadsPerThreadgroup` tag 0x08 |
| `pr-sampler-fallback.patch` | bug | — | sampler provisioning |
| `pr-compute-retire-scope.patch` | bug | — | compute quiesce (see its own doc) |
| `pr-sampled-resolution-latch.patch` | bug | — | publish-race latch for re-created refs |
| `pr-blit-texture-latch.patch` | bug | — | blit texture publish race |
| `pr-chain-resident-debt.patch` | bug | — | chain resident writeback debt |
| `pr-linear-sample-mapping-latch.patch` | bug | — | linear sample ↔ mapping latch |
| `pr-gather-pays-writeback-debt.patch` | bug | — | gather pays the debt first |
| `pr-stamp-page-reissue.patch` | bug | — | re-issue superseded stamp writes |
| `metal2vulkan-scalar-aggregate-store.patch` | bug | vendored translator | scalar store into aggregate |

The three **design** patches and both **diagnostic** patches are deliberately
separate from the bug fixes so the upstream report can present them separately.

## 5. Verification

- **Patch sequence.** Applied in `default.nix` order to the pre-image, the
  series reproduces the tested tree exactly (`diff -rq` empty; the tree used for
  all boots). Each patch also applies and compiles individually.
- **Tests.** `reims-vgpu-protocol`: 390 pass. `reims-vgpu-vulkan`: 629 pass
  (+5, +8 aux targets). Engine `backend::vulkan::translate`: 35 pass. The full
  `reims-vgpu` lib suite has ~55 pre-existing failures on the unmodified
  pre-image (timing/phase, mapper, observe modules) that are **not** caused by
  these patches; they are masked in the build.
- **Build.** `nix build --impure --no-link --print-out-paths -f
  /tmp/opencode/reims-qemu.nix` is green with the whole set.
- **Boot.** `run-game.sh <qemu-bin> <tag>` boots and presents; the driven
  checks are the counters named in §2.

## 6. Diagnostics (temporary)

`pr-diag-sampled-depth.patch`, opt-in with
`REIMS_VGPU_DIAG_CHAIN_READBACK=1`:

- `depth_resident_use identity=… wxh stencil=…` — the identity the render side
  keys each depth resident under.
- `depth_mark_ready identity=…` — every depth identity that actually received
  content.
- `diag_depth_sample_probe task=… ref=… fmt=… wxh [stencil=… ready=…]` — the
  candidates a sampled bind asks about.
- `diag_chain_target` / forced readback of a chain resident, so a scene
  target's rendered content is observable on the `m2v_store_gva … rgb_nz=` line.

`pr-diag-stamp-census.patch`: per-second stamp-slot census (pages, held
position, queued word, parked counts).

Both are marked for removal; they are not part of the fix series.

## 7. Open issues

1. **Performance.** §3; the sound fix (map-generation-keyed walk cache) is a
   design call, not implemented.
2. **Ping-pong depth identity.** The render/sample reference mismatch (§2.8) is
   why the "latest depth resident" heuristic exists. If the guest's two names
   are genuinely one allocation, an allocation-keyed identity for depth
   residents (as `pr-gva-debt-by-allocation` does for debts) is the principled
   replacement; if they are two textures, the sampled one must be produced by a
   rail this device does not implement (a depth copy/resolve).
3. **`Star Birds` is completely black** and was not diagnosed. Its run also
   shows `vk_slab_allocate_memory` (`A_device_memory_allocation_has_failed`)
   after the reclaim retry on a 1920×942 target, so memory pressure (or a leak
   in the newly admitted formats) is a candidate; its own formats/passes need
   the same refusal survey.
4. **`blit_fail reason=t2t_extent_oob`** for mip levels ~7–11 (~1 000/boot):
   texture-to-texture copies whose size does not fit the level. May explain
   remaining texture blur (stale/missing mips). Not yet diagnosed.
5. **Remaining artifacts in Easy Red 2:** a flat depth-driven "fog" over 3D
   objects and occasional pink patches. Pink is plausibly the `RGBA8Snorm`
   normal buffer (admitted late; unverified visually), fog is plausibly the
   neutral/heuristic depth content (§2.6). Both need a driven re-check on the
   current build.
6. **`vk_draw_validate_guest_sample_length` / `reason=linear_sample`** refusals
   at ~12–16 per boot remain. Not yet diagnosed.
7. **Guest-side changes made for diagnosis that are not part of any patch:**
   SIP is disabled in the guest (`csr-active-config = e7 03 00 00` in the
   OpenCore NVRAM; backup `~/reims-vgpu/vm/disks/OpenCore.qcow2.orig`) so
   `dtrace` fbt probes work. The guest password is temporarily `12345678`.

## 8. Upstream plan

- Send §2.1–§2.7 and the two metal2vulkan patches as a fix series, each with
  the counter/line quoted above as the failing observation.
- Open a separate design discussion for §2.6 ping-pong depth, the neutral
  fallback, and §2.8 allocation identity, with the probe output included.
- Open an issue for §3 with the `drain_duty`/`gpu_span` tables and the withdrawn
  memo's invalidation analysis, framing the walk cache as a proposal.
- Keep `pr-diag-*` out of the series.

## 9. Reproduction

```sh
# Build (the flake inputs pin the device source and the QEMU fork)
nix build --impure --no-link --print-out-paths -f /tmp/opencode/reims-qemu.nix

# Boot (cleanly shuts any running guest down over SSH first)
/tmp/opencode/run-game.sh <qemu-bin> <tag>
#   REIMS_VGPU_LAZY_WRITEBACK=off REIMS_VGPU_DRAW_LOG=on
#   add REIMS_VGPU_DIAG_CHAIN_READBACK=1 only for the §6 probes

# Guest: ssh macos-vm (localhost:2222, key ~/.ssh/id_ed25519)
# Game log: ~/Library/Logs/Corvostudio/Easy Red 2/Player.log
# Device logs: /tmp/reims-vgpu-fail.log, /tmp/reims-vgpu-draw.log
```

Useful lines in the verbose log: `drain_duty` (duty and per-draw µs),
`draw_phase` (phase split), `chain_phase` (`sampled_us`), `gpu_span` (GPU time
by submission kind), `engine_delta` (object churn), `store_routes` (all
counters). Useful lines in the fail log: `linux_m2v_draw reason=…` (per-pipeline
refusals), `rt_resolve reason=…` (render-target resolution), `resolve_field_ordinal_undefined`.
