# Reims vGPU: code-level assessment of the shipped patch series

Scope: an independent read of the device source, the vendored translator, and every
patch in `packages/reims-vgpu/`, plus static and logged evidence and test runs.
Companion to [`reims-vgpu-black-3d-scene.md`](./reims-vgpu-black-3d-scene.md), which
records the investigation; this document records what the code actually does, what is
actually deployed, and which parts of the recorded verification are reproducible.

Method: reconstruct the shipped tree from the pinned revision and the patch files;
read the resulting code at each change site; check the deployed binary for the patch
markers; re-run the test suites; read the device logs for the refusals the
investigation reported. No VM was booted for this assessment.

Line numbers below are from the *patched* tree (the patch series shifts them); the
repository paths are stable.

---

## 1. What is actually built and deployed

**Ground truth reconstructed.** `git archive` of `reims-vgpu` rev
`69a57dd69a6958e946c03b73e02db331f330f435` + the 22 device patches in the order
`packages/reims-vgpu/default.nix` applies them + the 3 `metal2vulkan` patches
reproduces the shipped tree. Every patch applies with offsets only (no fuzz), and the
result is byte-identical to `/tmp/opencode/t0-features` **except** for three hunks in
`crates/reims-vgpu/src/runtime/draw/vulkan.rs` — the withdrawn sampled-resolution
memo.

Consequences:

- `/tmp/opencode/t0-features` and `/tmp/opencode/verify-series` are **memo-era
  artifacts**, not the shipped tree. §5 of the investigation doc ("the series
  reproduces the tested tree exactly") was true when it was written and is now stale.
- The memo is genuinely gone from the shipped code: zero occurrences of
  `SampledResolutionMemo` / `latch_sampled_resolution_memo` /
  `sampled_resolution_memo_hit` in the package patches or the reconstructed tree, and
  the deployed binary contains no `sampled_resolution_memo_hit` string.
- The deployed QEMU (`/nix/store/6pgb96…-qemu-reims-vgpu-0.1.0-unstable-2026-09-03`)
  contains the markers of the *current* series: `depth_resident_sample`,
  `depth_resident_latest`, `depth_sample_neutralized`, `try_texture_resident_sample`,
  `recent_ready_depth_resident`, `chain_gva_debt_armed`,
  `gvarung_resident_cross_task`, `rt_linear_format`,
  `multisample_store_action_unsupported`, `SPV_KHR_shader_draw_parameters`,
  `diag_depth_sample_probe`. The running system and the patch files agree.

**`~/reims-vgpu` is not the shipped tree.** Eleven files differ. For nine of them
(`core/pass.rs`, `core/resolve.rs`, `protocol/pass_action.rs`, `paging/regions.rs`,
`engine/host_ram.rs`, `runtime/mapper/mod.rs`, `runtime/render_writeback/*`,
`runtime/drain/tests.rs`) the checkout is at the pinned revision — it does **not**
contain the pre-existing patch set (pr81/pr79, store-action). In three files
(`engine/mod.rs`, `runtime/drain/mod.rs`, `runtime/draw/vulkan.rs`) it holds hand
edits *and the withdrawn memo*. Nothing built or booted comes from this checkout; it
is a scratch tree and should not be read as the device's behavior.

**Translator artifacts.** `/tmp/opencode/m2v` is pristine + the two *feature* patches
only: it still contains the storage-class guard the scalar-aggregate-store patch
removes, and lacks that patch's test. The faithful "shipped translator" tree is
pristine + all three package patches (reproduced here and verified by the package's
own build-time greps: guard absent, test present, `VertRole::BaseVertex`,
`LoadBoolSelect`, `SPV_KHR_shader_draw_parameters` present).

---

## 2. Patch-set mechanics: defects found

1. **`pr-shader-draw-parameters.patch` is not a valid git patch.** Its `context.rs`
   header is
   `--- a/crates/reims-vgpu/src/backend/vulkan/engine/context.rs` /
   `+++ b/crates/reims-vgpu/crates/reims-vgpu/src/backend/vulkan/engine/context.rs`
   (duplicated prefix, patch lines 93–94). GNU `patch` tolerates it by writing the
   `---` name, which is why the build is correct — the change is in the deployed
   binary (`context.rs:1222–1242`) — but `git apply`/`git am` fail on it. Applying
   the whole series in order with `git apply` fails **only** on this patch.
   For a series whose stated purpose is to be sent upstream, this is a blocker.
2. **Eight of the new patches put `+++` before `---`**
   (`pr-chain-gva-writeback-debt`, `pr-depth-neutral-fallback`,
   `pr-depth-resident-latest`, `pr-depth-resident-sample`, `pr-diag-sampled-depth`,
   `pr-gva-debt-by-allocation`, `pr-msaa-store-and-resolve`,
   `pr-render-target-formats`). Both `patch` and `git apply`
   accept it, but it is not a valid unified-diff header order and some tooling
   (and human reviewers) reject it. Regenerating with `git diff`/`format-patch`
   fixes 1 and 2 together.
3. **`reims-pre` is not a pre-image.** It already contains
   `pr-store-action-deferred`, `pr-shader-draw-parameters`, `pr-stamp-page-reissue`
   and `pr-diag-stamp-census` (verified by reverse-apply), which is why those patches
   fail to apply to it and why `/tmp/opencode/patches3` has both application and
   removal directions. The doc's claim "each patch also applies and compiles
   individually" therefore does not hold as stated: against `reims-pre`,
   `pr-depth-resident-sample` fails in `translate/pixel.rs` (it was generated on top
   of `pr-render-target-formats`' re-export list) and `pr-diag-sampled-depth` fails
   in two hunks (it needs the depth rails). These are ordinary stack dependencies —
   the point is only that the verification statement as written is not reproducible.
4. **`.orig` files.** GNU `patch`'s backup-if-mismatch leaves `engine/mod.rs.orig`
   and `runtime/draw/vulkan.rs.orig` in the build tree because those patches apply at
   an offset. Harmless, but it is a signal: `pr79.patch` was generated against a tree
   one line off the pinned revision, and `pr-gva-debt-by-allocation` applies 146
   lines off (post-memo-removal numbering). Any silent-context drift is invisible to
   the build; only the three `metal2vulkan` patches have build-time gates (grep for
   their own marker strings). A cheap improvement is a `patch --dry-run`-style gate
   or an exact-application check for the device patches too.

---

## 3. Verification state: what reproduces and what does not

**Not reproducible as shipped: the `reims-vgpu` crate's tests do not compile.**
`pr-depth-resident-latest.patch` added a `depth_target_ref: u32` parameter to
`resolve_sampled_source` and updated the production call site but not the five test
call sites in `crates/reims-vgpu/src/runtime/draw/tests.rs` (lines 3804, 4546, 4568,
4684, 4883). With the shipped tree, `cargo test -p reims-vgpu` fails with five
`E0061` errors. The nix build never compiles test targets, so this is invisible to
the build and to every boot.

With a five-line fix applied in a scratch copy, the numbers reproduce:

| Target | Result |
|---|---|
| `reims-vgpu-protocol` | 390 passed, 0 failed |
| `reims-vgpu-vulkan` | 629 passed, 0 failed (+5, +8 aux targets) |
| `reims-vgpu --lib backend::vulkan::translate` | 35 passed, 0 failed |
| `reims-vgpu --lib` (full) | ≈2174–2180 passed, 53–59 failed |
| `reims-vgpu --lib` on the pre-image (no new patches) | ≈2180–2194 passed, 39–53 failed |

The full-suite failure count is **flaky run to run** (the failing set is concentrated
in timing/phase/census/observe/decode tests, and the two trees' failing sets overlap
almost entirely but not exactly). So "~55 pre-existing failures, not caused by these
patches" is broadly right, but the suite in its current state cannot distinguish
"pre-existing" from "introduced" for anything. That matters more than usual here
because the *new* code that most needs a witness — `recent_ready_depth_resident`,
`try_texture_resident_sample`, the neutral fallback, `gva_debt_at` — has **no test at
all**; only `sample_view_format` gained one. This is exactly the situation the
investigation's own §3 warns about ("no test covered it, so the green suite was not
evidence").

**Untested conversion math.** `pr-render-target-formats.patch` adds six new
conversion helpers (`rgba8_to_rg11b10_word`, `rgba8_from_rg11b10_word`,
`rgba8_channel_to_uf`, `uf_to_rgba8_channel`, `unorm8_to_snorm_byte`,
`snorm_byte_to_unorm8`, `pixel_format.rs:2707–2812`) and **no `#[test]`**. The
existing suite covers the new formats only structurally (exhaustive enums, capability
masks, "every renderable format maps to a render-target layout"), which is real
coverage of table completeness but none at all of the arithmetic. Reading the
arithmetic: the RG11B10 packing (R in bits 0–10, G 11–21, B 22–31, 5-bit exponent
bias 15, 6/6/5 mantissas) and the RGB10A2 shifts (`pixel_format.rs:2668–2671`, R 0,
G 10, B 20, A 30) are correct, as is the unorm→snorm→unorm round trip's endpoints —
except that `unorm8_to_snorm_byte`'s doc-comment says "0 becomes `-128`" while the
code computes `-127` (`pixel_format.rs:2770–2776`). Self-consistent with its inverse,
so not a rendering bug; a documentation/one-LSB defect in code whose whole point is
to be auditable.

---

## 4. Per-fix assessment

Confidence is from reading the resulting code, not from the patches' comments.

**Verdicts, patch by patch** (the code as shipped; defects are in §5)

| Patch | Assessment |
|---|---|
| `pr81`, `pr79` | Upstream PRs; both fixes are real in the shipped tree (`pr81`: the image's own `bytes_per_texel` is threaded through `geometry()`/`plan_regions`/`plan_guest_copies`; `pr79`: the release settle really waits). Two risks on `pr79` and one regression against it are recorded in §5.8 and §5.12. |
| `pr-compute-retire-scope` | Replaces a device-wide quiesce with the readback entry's own fence. The wait's premise (the copy is submitted before the fence wait) holds in the code read; the periodic maintenance the comment claims is on the poll heartbeat. |
| `pr-store-action-deferred` | The ordinal is accepted and the executor applies overrides by slot exactly as the API requires, but the `resolve.rs` half is inert for the dependency graph and the model and the rail still disagree about an un-overridden `4`. See §5.1. |
| `pr-sampler-fallback` | Releases the bind instead of refusing the draw; the fallback sampler is provisioned by the reflected-sampler path, so nothing statically used is left unbound, and the loss stays reported. The *shade* can be wrong rather than merely default: the normalized default is linear/clamp and the guest's `lod_clamp` is dropped, so a nearest or repeat sampler is served blurred or edge-smeared; a reflected static sampler with bicubic/lod-bias still refuses the record. |
| `pr-threadgroup` | The TLV walk is length-driven, so tag 0x08 consumes its own words and cannot mis-parse a neighbour; the value is dropped rather than clamped, which is correct here because nothing on this rail reads it. The risk is the widened benign list itself: index 8 is now silently accepted-and-ignored for any pipeline whose serializer means something else by it (identification rests on one live capture). |
| `pr-msaa-store-and-resolve` | Store action 3 now follows the same path as the previously accepted resolve-only 2, and the resolve is genuinely performed (the resolve flag comes from the multisample source ref, and the pass always carries a resolve attachment). The LOAD half is admitted on the chain position rather than on the pool's own reuse key — see §5.6. |
| `pr-depth-resident-sample` | The right direction: a depth attachment's only copy is a texture-keyed resident, and `sample_view_format` returning the resident's own format for a depth image is required for a legal view. |
| `pr-render-target-formats` | The four formats' byte layouts, byte order, Metal↔Vulkan spellings and pack/unpack math are correct (the RGB10A2 pair was brute-forced as an exact inverse; RG11B10's shifts match the spec). But the patch also arms the CPU loader for the two HDR layouts without marking them lossy (§5.13a), admits `R16Unorm` with no CPU rail (§5.13b), and carries an unrelated revert of `pr79`'s compute window guard (§5.8). |
| `metal2vulkan-base-vertex`, `-front-facing-int`, `-scalar-aggregate-store` | See §6. |

**Heuristic or unproven (the code is coherent, the premises are not established)**

- `pr-depth-resident-latest`: serves *any* ready depth resident of the same width and
  height that is not the draw's own depth reference (`images_and_registry.rs:808–830`).
  It is a substitution of another texture's content, decided by recency, with only a
  counter (`depth_resident_latest`) and no fail-channel line. See §5.3.
- `pr-depth-neutral-fallback`: serves a 1×1 `{255,255,255,255}` reading for any depth
  sample no rail could serve. It is at least fail-visible once per `(task, ref)`
  (`draw/vulkan.rs:1920–1965`), and reading far rather than near is the right default.
- `pr-gva-debt-by-allocation`: bridges `NoGeneration` to a debt found by
  `(gva, width, height)` across *any* task (`writeback_debt.rs:558`). Bounded
  (`MAX_DEBTS = 32`) and the resident is re-checked for readiness, but the key is an
  address, not an allocation identity. See §5.4.
- `pr-chain-gva-writeback-debt`: arms the GVA ledger for `mid == 0` chain targets —
  correct and minimal. Note the third case arms nothing and logs nothing:
  `mid == 0 && target_gva == 0` falls into the mapping-keyed arm, which refuses
  `mid = 0` (`draw/vulkan.rs:226–260`).
- `pr-linear-sample-mapping-latch`: **cannot fire** — it compares a GPA byte address
  against a raw encoded page entry, so the mapping-keyed debt is never paid through
  the texture ref. See §5.9.
- `pr-stamp-page-reissue`: discards its repair on a `Settled` answer, which is the
  case it exists for; the keep/drop gate is also inverted relative to its own comment.
  See §5.10.
- `pr-sampled-resolution-latch`, `pr-blit-texture-latch`: the gate is age-only
  (250 ms from the first empty read), the latched value carries no generation or
  incarnation, and both tables are process-wide with no removal path, so a recycled
  ref can be served a different resource's backing. See §5.11.
- `pr79`'s release settle: the `retire_all` shape, two uncovered delete paths, and a
  debt flag cleared after a failed wait. See §5.12.

---

## 5. Defects found by reading

### 5.1 The store-action fix is only half connected

Three separate things, all verified by reading the shipped tree.

**(a) The `resolve.rs` override cannot affect the dependency graph.** The patch's own
comment says "participations are computed from the arena *after* the whole stream
resolves" (`core/resolve.rs:1146–1152`). They are not: the walk resolves one record
and immediately records it (`core/walk.rs:271–279`), and `ExecBuilder::record`
derives participations at that instant (`core/exec.rs:842–844`). The only reader of a
pass descriptor's participations is that call (`core/exec.rs:159–167` →
`pass.rs:401–409`, where the resolve-target write is emitted only when
`attachment.store.resolves()`). So when the `WriteDescriptor` record is recorded, the
pre-override ordinal (`4 → Store`, `resolves() == false`) has already decided there is
no write edge to the resolve target; the later `SetStoreAction` mutates the arena copy
after that decision is frozen into the access list. The patch's new test asserts only
the arena's stored value, so it passes while the graph effect is nil. The user-visible
shape is the one the patch exists for: the engine resolves into the resolve target
while the model orders only the MSAA attachment, so a later reader can see stale or
torn content with no hazard edge to prevent it.

**(b) Model and rail disagree about an un-overridden `4`.** `StoreAction::parse(4) =
Store` gives the model a Write participation, but the rail asks the raw ordinal:
`store_action_publishes_single_sample(4) == false`
(`protocol/pass_action.rs:403–410`) → `store_is_store = false` → `skip_readback = true`
(`runtime/draw/vulkan.rs:9325–9345`), and the store rails are gated on that
(`:9362`, `:9371`, `:9429`). The shipped build's log shows this case is live — the
`pass_state_degraded reason=store_action_unmapped … store_action=4` lines below mean
the *final* action of those records was still 4, because the runtime applies
`SetStoreAction` into the accumulator before the request is built
(`runtime/exec/mod.rs:3776–3778`, `:5618`). For those passes the model records a
"store" no rail performs. (`Settled`-vs-`Queued` rails aside, the GVA/mapper rails do
arm their own debts, so the frame is not necessarily lost — but the two planes
disagree and the only trace is a log line that says the opposite of the truth.)

**(c) The contract check still calls `4` unmapped.** `store_action_in_contract`
(`runtime/draw/mod.rs:1765–1778`) asks `is_declared_store_action`, which by design
excludes 4, and then logs that the attachment "may be dropped" — live lines in
`/tmp/reims-vgpu-fail.log` (`pipe=2564 store_action=4`, `pipe=2193`, `pipe=2456`).
It is a report, not a refusal, but it makes the fix read as an unresolved defect on
the fail channel.

**(d) A related snapshot bug is newly reachable.** `acc.clears` copies the attachment
when the descriptor is walked (`runtime/exec/mod.rs:3747–3749`) and
`clears_reaching_guest_pages` filters on that copy's raw ordinal (`:244–248`), so a
clear-only stream whose descriptor says 4 and whose stream then overrides to
Store/resolve publishes **no** clear (`:4956–4962`, `:5438`) while the model says it
stored. Before this patch such a stream was refused outright, so the patch makes the
case reachable.

The same blind spot is why the *class* is not closed: `MTLStoreActionUnknown` was the
one ordinal the guest actually sent, but the mechanism that cost 84 % of a Unity
title's packets was "a descriptor field the model cannot name refuses the whole
packet". Ordinal 5 (`CustomSampleDepthStore`) is now declared beside the four and
still parses to `None`, so a title that uses it loses every render pass the same way.
The executor already has a degradation vocabulary for exactly this
(`pass_state_degraded`); the ordering plane's refusal could follow it.

### 5.2 Two measured refusals have identifiable root causes

- **`blit_fail reason=t2t_extent_oob`, ~1 000/boot.** The log carries the internals:
  `blit_extent reason=blit_extent_over kind=t2t_src axis=h requested=4 available=2`
  for `level: 9 … size: Size { width: 4, height: 4, depth: 1 }`. The guest is copying
  one *block* of a block-compressed mip chain; the device compares that block-unit
  size against the level's **texel** extent (level 9 of a ~1024-wide chain is 2×2
  texels). The bounds check at `runtime/blit_exec/mod.rs:3186–3205` is not
  block-aware, even though the code immediately below it documents that from that
  point on "the unit is a 4x4 block". The fix is to compare in block units or to
  round the available extent up to whole blocks (`BlockGeometry::blocks_across` /
  `block_rows` already exist and are used by the sibling checks in `exec.rs`). This
  is pre-existing code, not one of the new patches; it is also the cheapest open
  defect to close.
- **`vk_draw_validate_guest_sample_length`, ~12–16/boot.** The log names the numbers:
  `binding=706 actual=8388608 expected=65536` on a 1920×942 pass with `fmt=0x5c`
  (`expected` is a 128×128×4 = 64 KiB level; `actual` is 8 MiB, the whole
  allocation/chain). The check is an exact-equality assertion between the guest's
  declared linear-sample window and the device's computed tight footprint
  (`engine/exec.rs:1972–1980`, `draw_validation.rs:199`). A window *larger* than the
  level's footprint is not a hazard for a bind whose row stride is separately checked
  (`GuestSampleRowStride`); the equality is what refuses. Whether to relax it to
  "the window must contain the level" is a maintainer's call, but the counter already
  carries the two numbers that decide it — the next step is a census of
  `(actual, expected, block geometry, level)` rather than more boots.

### 5.3 The depth resident identity cannot express what the code asks of it

`TargetIdentity::Texture` is `{ ref_, width, height, generation: 0, stencil }`
(`engine/types.rs:1822–1839`) — no level, no slice, no depth plane. Two consequences:

- `depth_chain_identity` keys the resident by the **colour** attachment's extent
  (`draw/vulkan.rs:10327–10350`), while `try_texture_resident_sample` looks it up by
  the **depth texture's own** extent (`draw/vulkan.rs:4694–4740`). When those differ
  (a depth texture larger than the render area, a scaled target), the sampled bind
  silently finds nothing and falls through to the heuristics below. When they agree
  (the common case) it works.
- A depth texture with mip levels or array slices collapses to one resident per
  `(ref, w, h, stencil)`. Rendering slice 1 overwrites slice 0's resident, and a
  sampled bind of either slice can be served the other. This is a latent aliasing
  defect in the depth rail the new patch builds on; for the current guest (single
  1920×942 camera depth) it is invisible, for shadow cascades or cube depth it is not.

On top of that, `recent_ready_depth_resident` answers "which depth texture did the
guest mean" with "the most recently ready one of this size, unless it is this draw's
own attachment". For the measured case (render ref 306 vs sample ref 308, 90 vs 60)
that is very likely right. For a second camera, a reflection pass, or a depth texture
that is genuinely not the frame just rendered, it is wrong and unfalsifiable at
runtime — and unlike the neutral fallback it does not even leave a fail line, so a
wrong serve cannot be attributed without the opt-in probes.

The principled answer is available and is not exotic: the sampled bind already
decodes its own descriptor and can name its level-0 GVA
(`tex.level_gva(0, page_shift)`, used by `try_gva_resident_sample`); the render side
resolves the depth texture to create its image. Recording the depth attachment's
backing (its GVA or the guest page-list identity) in the depth resident's identity
would let a sampled bind ask "is there a resident of *this allocation*", which turns
the latest/neutral heuristics back into fallbacks for genuinely absent content. That
is the design change open issue §7.2 of the investigation asks for; this reading adds
that the pieces are already in the tree.

### 5.4 `gva_debt_at` is an address-keyed bridge, and address keys are reusable

`gva_debt_at(gva, w, h)` matches any live debt whose window *starts* at that GVA with
that geometry (`writeback_debt.rs:558–565`), tried under the bind's format then the
debt's. The population is bounded at 32, which limits the blast radius. Two failure
shapes remain: a freed allocation remapped at the same address while an unpaid debt
for the old one is still live (false positive — the wrong resident is served as if it
were this texture's), and the same allocation described by two objects at different
offsets (miss — the bridge does not fire because the GVA differs). Neither is
tested. If the cross-task case matters, the ledger already carries the resource
generation and the page list; comparing the *backing* (the first physical page or the
retained page list) rather than the window start would make it an allocation test
instead of an address test.

### 5.5 `pr-depth-resident-sample` bypasses the swizzle gate

Every other resident-serving arm in `resolve_sampled_source` honours
`may_bind_resident` (derived from "the bind's view has no channel remap",
`draw/vulkan.rs:8122`), because a direct resident bind cannot carry that remap
(`draw/vulkan.rs:1515–1526`, `1591–1600`). The new depth arm is placed *above* that
gate and ignores the flag (`draw/vulkan.rs:1884–1890`). Either the engine composes
Target binds' swizzles (in which case the older gates are over-conservative) or this
rail drops a channel remap. For a depth bind the practical impact is small, but the
inconsistency is exactly the kind the surrounding comments exist to prevent.

### 5.6 The MSAA LOAD acceptance is gated on the chain position, not on the reuse condition

Accepting store action 3 is right, and the resolve really does happen: the engine
sets `multisample_resolve` from `multisample_source_ref != 0`
(`draw/vulkan.rs:9160–9165`), independent of the action, and the render pass always
appends a resolve attachment whose store is `STORE`
(`engine/caches.rs:2191–2206`).

The LOAD half is subtler. The patch admits `LOAD` when `req.continues_render_pass`,
justified by "the engine keeps one multisample target per key and reuses it". The
reuse condition is narrower than the chain position: `acquire_multisample_target`
reuses the slot only when `slot.key == key && !key.transient_depth`
(`engine/pools/submission_and_buffers.rs:4015–4022`), where the key includes the
resolve view and the depth view, and `transient_depth` is true whenever the depth
attachment is owned by the draw (no guest depth texture). In that case — and for any
continuing record whose key differs — a **fresh** multisample image is created while
the pass begins with the colour-0 load op, which the chain retarget has forced to
`LOAD`; the resolve then reads undefined content for pixels this record did not
shade. The guest-visible symptom would be scattered garbage, not a black frame, which
makes it easy to misattribute. Gating the acceptance on the same condition the pool
uses (or passing the key down) removes the guess.

### 5.7 The performance proposal's key does not cover a known mutation class

The investigation's §3 proposes caching page-table walks keyed by
`MappingEntry::map_generation`, on the premise that "a remap necessarily bumps the
generation". The codebase documents the counterexample in its own words: a guest that
re-points a backing surface in its own page table produces **no packet**, so
`map_generation` does not move, and the device's cached entries stay trusted — the
reason `backing_pages_witness` re-walks every page and reports
`backing_pages_stale sid=49 … (task PT translation moved; rebuilding)`
(`runtime/mapper/mod.rs:1150–1215`). A walk cache keyed on `map_generation` alone
would reintroduce that staleness for sampled resolution, which is the same defect
class the withdrawn memo died of. The sound versions are: cache with the existing
per-page witness (which costs a walk and so may still win if the walk is cheaper than
the rest of resolution), or don't cache the walk at all and remove the *number* of
resolutions per draw instead (the same texture is re-resolved for every bind and
every pass; a per-packet or per-draw dedupe keyed on the descriptor plus the
witnesses the rails already compute is a smaller, testable change).

---

### 5.8 A later patch silently reverts part of `pr79`

`pr79.patch` adds a total-extent guard to both compute direct-destination arms: it
refuses the direct landing and falls back to the pooled readback when
`licence.target.window_shortfall()` says the storage image names more texels than its
guest pages hold (`pr79.patch` lines 246, 280, 303).
`pr-render-target-formats.patch` — generated later, and applied after `pr79` in
`default.nix` — deletes both call sites as part of its diff (the two hunks at
`pr-render-target-formats.patch:716–740`). In the shipped tree
`window_shortfall` has **no caller**: only its definition remains
(`engine/mod.rs:3729`), and the compute arm goes straight from an `Ok(licence)` to
`ComputeImageDestination::GuestPages` (`runtime/compute_exec/vulkan.rs:158–168`).

This is the classic cost of a patch stack that is not re-derived from its base: the
formats patch was cut against a tree in which `pr79`'s guard had been removed (the
same removal-direction editing that produced `patches2/`), so its diff carries an
unrelated revert. Both compute licences currently require full page coverage
(`ordered_complete` / `plan_guest_window`), so this is lost defence-in-depth rather
than a demonstrated hole — but the shipped series does not contain the change its
inventory says it does, and the build cannot see it (it compiles; the function simply
becomes dead).

### 5.9 `pr-linear-sample-mapping-latch` cannot ever fire

The latch compares a guest **physical address** against a **raw encoded page entry**:

```rust
// draw/vulkan.rs:4814–4822
if mapping.page_entries.iter().any(|&page| u64::from(page) == first_page)
```

`page_entries` hold `(valid bit | PFN << 2)` words (`PAGE_ENTRY_VALID = 0x1`,
`PAGE_ENTRY_PFN_SHIFT = 2`, `protocol/iosurface_pages.rs:107–108`), while `first_page`
is `packed.gpas.first()` — a page-aligned GPA byte address
(`draw/vulkan.rs:5051–5058`), the same value the rail hands to `host.map_pages`. A
valid entry always has bit 0 set; a page-aligned address never does (and a GPA is
usually wider than the `u32` entry anyway). The predicate is therefore false for every
mapping, so `texture_to_mapping` is never written by this rail and a mapping-keyed
writeback debt is never paid through a texture ref on the linear-sample path — the
exact gap the patch was written to close (`wbdebt_texture_owes_nothing_unresolved`).
The fix is to decode the entry (`entry_gpa_shift`, already in the protocol crate) or
to compare PFNs. The loop's other weaknesses stand even after that: it scans every
mapping in the device rather than the task's, and the insert is first-writer-wins and
never refreshed.

### 5.10 `pr-stamp-page-reissue` discards its repair on a `Settled` answer

`StampOrdering::Settled` means "**the caller writes the word**"
(`backend/mod.rs:1170–1171`); the main publication path honours that by writing the
page (`runtime/drain/mod.rs:3245–3260`). `reissue_pending_stamps` does not: it drops
the pending point on any non-`Queued` answer, commented as "the rail ordered it inline
or wrote the page itself" (`runtime/drain/mod.rs:2620–2626`). The Vulkan rail returns
`Settled` exactly when nothing is in flight for that slot or after a full quiesce
(`runtime/drain/vulkan.rs:137–159`) — which is precisely the state a superseded queued
write leaves behind. So the repair is discarded in the case it exists for, the page
stays behind the plane's point, and the guest's channel keeps re-reading the fence.
The keep/drop gate in `settle_pending_stamp_pages` has a matching polarity trap: it
keeps a point the *plane has already reached* and drops one it has not
(`runtime/drain/mod.rs:2554–2578`), while the page read that just proved the guest is
still behind is the reason the entry exists.

### 5.11 The two publish-race latches are age-only, and their tables are permanent

`pr-sampled-resolution-latch` and `pr-blit-texture-latch` both serve a last-known
backing when a ref's slot reads empty, gated by
`pending_publication(task, ref, PUBLISH_RACE_WINDOW_US = 250_000)`
(`objects/slot_recheck.rs:516–525`) — i.e. by *age since the first observed empty
read* and nothing else. What they latch carries no generation or incarnation:
`(w, h, mid, SampledSourceRequest)` for a sample, `TextureBacking`
(`base_gva`/`alloc_size`/`row_stride` or `mapping_id`) for a blit
(`draw/vulkan.rs:1200–1235`, `blit_exec/mod.rs:532–570`). Both tables are
process-wide statics with an insertion cap and **no removal path** (verified: only
insert/get), keyed by `(task, ref)` with no task incarnation. Serving on a miss means
the value served is the last *successful* resolution of that key, so the risk is not
"stale by up to 250 ms" in the harmless sense: a recycled ref that now names a
different resource can be served the old resource's extent, mapping, or bytes for up
to ~15 frames, and the blit will upload content read from the old GVA. It is bounded
and refreshed on every success, and the alternative is a refused draw or a failed
upload — but an incarnation dimension (or dropping the entry when its watch ends)
would make "one frame late" true rather than aspirational.

### 5.12 `pr79`'s release settle is the `retire_all` shape `pr-compute-retire-scope` removed

The release path (`settle_release` → `render_writeback::settle_guest_writes` →
`engine::quiesce_guest_writes` → `pools.quiesce_guest_writes` → `retire_all`,
`runtime/drain/mod.rs:5431–5451`, `engine/mod.rs:1723–1770`,
`pools/submission_and_buffers.rs:3009–3021`) flushes every open batch and waits
**every** ring slot's fence (5 s each) while holding the engine lock, on the
packet-processing thread. No deadlock was found, but it is the same whole-device wait
`pr-compute-retire-scope` deliberately removed from the compute readback path, and it
runs for every `UnmapMemory`/`DeleteIOSurfaceBacking2` with any writeback outstanding.
Two further gaps: `DeleteTask` and `DeleteResource` retire debts and bound buffers but
take no settle at all (`runtime/drain/mod.rs:792–819`, `:6316–6346`), so a task that
dies without a per-range unmap can have a submitted writeback land in recycled pages;
and a timed-out wait still clears the outstanding-debt flag
(`engine/mod.rs:1753–1757`), so every later release short-circuits at
`if !backend.guest_writes_outstanding() { return; }` while the pending slots still
hold writes.

### 5.13 The formats patch arms the CPU loader for HDR layouts and marks them exact

The four formats' *layouts* are right — independently verified against MoltenVK's
Metal↔Vulkan table and the spec's bit positions, with the RGB10A2 pack/unpack
brute-forced as an exact inverse over all 256 red values, RG11B10's shifts correct
(R 0–10, G 11–21, B 22–31), and the byte-copy claim holding for all four. Three
defects sit around them.

**(a) The cost floor now turns HDR sampled binds into 8-bit ones, silently.** The
patch adds CPU loader arms for `Rg11b10Float` and `Rgb10a2Unorm`
(`has_cpu_loader_arm`, `protocol/pixel_format.rs:1055`, `:1060`) but leaves them out
of `cpu_loader_arm_is_lossy` (`:1129–1131`), so
`a_cost_floor_may_decline() = has_cpu_loader_arm() && !cpu_loader_arm_is_lossy()`
(`:1166`) becomes *true* for both. That predicate is what
`sampled_gather_floor_admits` consults (`runtime/draw/vulkan.rs:2979`): a sampled
RGB10A2 or RG11B10 texture below the 64 KiB floor now has its **native gather
declined** and takes the CPU row conversion (`RowToRgba8::for_format` arms at
`pixel_format.rs:3441–3442`), where 10/11-bit channels are truncated to 8 and
RG11B10 values above 1.0 are clamped. This is the failure the sibling test
`a_cost_floor_may_only_decline_a_layout_whose_cpu_arm_is_exact` exists to prevent,
and it is not reported: `note_sampled_narrowing` early-returns unless
`narrows_to_unorm8(fmt)`, which still lists only `RGBA16Float`/`RG16Float`
(`pixel_format.rs:3328–3330`). Fix: mark both lossy (which also restores the
reporting), or drop the arms.

**(b) `R16Unorm` is admitted as a render target with no CPU rail.** It has no
`expand_rgba8_to_texel`, no `narrow_texel_to_rgba8`, no `rgba8_to_texel` arm and no
row-converter arm (`pixel_format.rs:2982`, `:3128`, `:3305`, `:3688`). Consequences
traced in the code: a Load-action seed refuses; a clear-only pass builds an RGBA8
clear image (`solid_clear_image`, `:2396`) that `write_gva_frame_within_skipping`
cannot convert, so the clear is dropped with a generic bad-args
(`runtime/draw/mod.rs:3143–3147`); and if the host declines the format as an
attachment, the copying Store rail has no converter and reports
`gvawb_copied_write_refused`. The `Rg16Uint` precedent (an integer target with no CPU
arm) makes this defensible, but the clear path is concretely broken, and the protocol
test that lists `R16Unorm` under "a layout no colour attachment takes" now asserts
something false.

**(c) The snorm storage-image refusal rests on a false spec claim.**
`compute_exec/vulkan.rs:1788–1793` (and its twin in
`reims-vgpu-vulkan/src/pixel.rs:1024–1029`) says `STORAGE_IMAGE` is not mandatory for
`R8G8B8A8_SNORM`; it is (the spec's mandatory table marks it unconditionally and the
CTS required-format array contains it). The refusal is conservative — no wrong pixels
— but the stated reason would not survive upstream review. Relatedly, only
`A2B10G10R10_UNORM_PACK32` of the four has a mandatory `COLOR_ATTACHMENT` floor, so
three admissions rely on the per-layout host probe and the 8-bit fallback; that
fallback is coherent, but "admitted" is not "rendered at full precision" on every
host.

**(d) Test coverage.** The patch adds no `#[test]`; it bumps two count tables (10→14),
and the exhaustive `u16` sweeps do enforce that every format has a consistent arm
somewhere. Nothing asserts the new conversions' absolute words, and the "widening and
narrowing are inverses" test omits all four new layouts.

---

## 6. Translator patches

The shipped translator tree (pristine + the three patches) was read **and exercised**:
the patched and pristine CLIs were run on the shaders the patches care about, with the
crate's own in-translate `spirv-val --target-env vulkan1.2` boundary, and the two new
tests were run.

- **base-vertex — correct-with-risks.** The roles are registered and lowered with
  `OpCapability DrawParameters` and `OpExtension "SPV_KHR_shader_draw_parameters"`,
  the variable is decorated and listed in the entry point, and the emitted
  `BaseVertex`/`BaseInstance` variables are `%uint` (which is what Vulkan requires —
  scalar 32-bit, signedness unconstrained — and what Metal's own types imply). Both
  new tests pass, both are discriminating (the pristine binary refuses the same
  shaders), and the tests are backed transitively by `spirv-val`. Two residuals:
  (a) a vertex function carrying `!air.patch` is emitted as a
  `TessellationEvaluation` entry point, where `BuiltIn BaseVertex`/`BaseInstance` is
  illegal (VUID-BaseVertex-04184); the pre-existing `vertex_id → VertexIndex` arm has
  the same problem, and the `InstanceIndex` special case at
  `stage_input/mod.rs:1492–1515` shows the author already knew the shape.
  (b) nothing declines the *translation* when the host lacks
  `shaderDrawParameters`; the module is then spec-invalid and fails at pipeline
  creation with a VkCall rather than at a named capability decline. Also, the doc
  comment's "zero for a non-indexed draw" is wrong (Vulkan reports `firstVertex`;
  the emitted code is right because Metal's `base_vertex` is `firstVertex` too), and
  `reflect::VertexBuiltins`/`footprint` gained no Base arms, so a base-only shader is
  invisible to the reflect-vs-emit census and a base-derived buffer index is
  unmodeled.
- **front-facing-int — correct.** The `OpSelect` result type, both objects, and the
  condition are type-exact for every integer width (i8/i16/i32/i64 verified through
  `spirv-val`), the shared `%gl_FrontFacing` bool is hoisted once, no Location or
  interface variable is created for the parameter, and a float/vector declaration is
  still refused by the type test. The test passes and is discriminating.
- **scalar-aggregate-store — correct.** The guard was not load-bearing anywhere else,
  the replacement forces the pointer pointee and value to the same type before the
  store, and the emitted access-chain + bitcast + store validates in every storage
  class the path now admits. The added test pins the type agreement with an explicit
  `spirv-val` call and fails without the fix. Residual: a mismatch that is not
  first-scalar/same-width (e.g. `i64` into `[10 x i32]`) still falls through to the
  invalid raw `OpStore`.

Two packaging observations on this group: the nix build-time greps are weaker than
the invariants they stand for (the scalar gate greps the literal guard line, so a
reformatted equivalent would false-pass; the base-vertex gate greps the extension but
not `Capability::DrawParameters`), and the front-facing test hunk only applies on top
of the base-vertex test hunk — which is why `/tmp/opencode/m2v-ff`'s test file is
byte-identical to pristine and contains no front-facing test.

---

## 7. Open-issue triage, with a concrete first step each

| Issue | First step |
|---|---|
| Store action: override does not reach the graph | Make the `SetStoreAction` override land before the pass's participations are derived (or resolve the segment before recording); align the rail's publish decision and `acc.clears` with the model's parse of `4`; then let the ordering plane degrade instead of refusing for ordinals the executor can name. See §5.1. |
| Formats: silent 8-bit sampled HDR | Mark `Rgb10a2Unorm`/`Rg11b10Float` lossy (or remove their CPU arms), add `narrow`/`expand`/row arms for `R16Unorm`, and add the round-trip assertions the new conversions lack. See §5.13. |
| `pr79` guard reverted by a later patch | Restore the two `window_shortfall` call sites in the compute rail (or record why they are gone); re-derive the formats patch against the true base. See §5.8. |
| Dead writeback latch | Decode the page entry in `latch_linear_sample_mapping` (or compare PFNs). See §5.9. |
| Stamp reissue discards its repair | On `Settled`/non-`Queued`, write the word the way the main publication path does (or re-insert). See §5.10. |
| Test target does not compile | Add the missing `depth_target_ref` argument at the five `tests.rs` call sites (a five-line fix; done in a scratch copy here to obtain the numbers in §3). |
| `t2t_extent_oob` | Make the t2t bounds check block-aware (`blit_exec/mod.rs:3186–3205`); the refusal evidence and the block helpers are already in hand. |
| `vk_draw_validate_guest_sample_length` | Emit the census the check already has the fields for (`actual`, `expected`, level, block geometry) and decide coverage-vs-equality from it. |
| Ping-pong depth identity | Record the depth attachment's backing in the depth identity and answer sampled depth binds by allocation; then `depth_resident_latest` and `depth_sample_neutralized` become measurable fallbacks rather than the mechanism. |
| Depth residents alias levels/slices | Add level/slice/plane to `TargetIdentity::Texture` (or refuse depth residents for non-zero level/slice and report), before the sampled rail depends on the identity further. |
| Performance | Do not ship a `map_generation`-only walk cache (see §5.7). Start from a per-draw/packet resolution dedupe with the witnesses that already exist, and add mutation tests for every invalidation class the memo's post-mortem lists. |
| `Star Birds` black + `vk_slab_allocate_memory` | Its own refusal survey is still the right first step; add the allocation census (site, format, geometry, population) on the failure path so memory pressure or a leak in the newly admitted formats is distinguishable from a resource-identity failure. |
| Remaining Easy Red 2 artifacts | The "fog" is plausibly the neutral/latest depth substitution (§5.3) and pink plausibly the late-admitted `RGBA8Snorm`; both are now readable from the counters (`depth_sample_neutralized`, `depth_resident_latest`, `rt_linear_format`). |
| Diagnostics in the shipped build | `pr-diag-stamp-census` and `pr-diag-sampled-depth` are in the deployed binary; keep them out of the upstream series (the investigation already says so) and out of any release build. |

---

## 8. Recommendations, ordered

1. **Repair the series before anything else.** Regenerate the patches with
   `git format-patch`/`git diff` (fixes the malformed header and the header order),
   fold in the five missing test arguments, re-derive every patch against its true
   base (the `pr79` guard revert in §5.8 came from not doing this), and separate the
   two diagnostic patches. Until the test target compiles, no claim in §5 of the
   investigation doc can be re-verified by anyone.
2. **Fix the formats patch's cost-floor regression (§5.13).** Mark
   `Rgb10a2Unorm`/`Rg11b10Float` lossy (or drop their CPU loader arms) so a sampled
   HDR texture under 64 KiB is not silently truncated to 8 bits, give `R16Unorm` the
   CPU rails it needs to be a render target, and restore (or justify deleting) `pr79`'s
   compute window guard.
3. **Close the refusal class, not just the ordinal (§5.1).** Make the contract check
   agree with `StoreAction::parse`, make the override reach the pass's participations,
   align the rail's publish decision with the model's, and give the ordering plane a
   degradation path for descriptor fields the executor can name.
4. **Make the depth identity exact (§5.3).** One allocation-keyed answer replaces
   three heuristics, removes a silent content substitution, and makes the residual
   cases (genuinely absent depth) countable.
5. **Repair the two dead or self-defeating writeback repairs** — the
   encoding mismatch in `pr-linear-sample-mapping-latch` (§5.9) and the
   `Settled`-answer drop in `pr-stamp-page-reissue` (§5.10). Both are small and both
   sit on the black-window path.
6. **Fix the two measured refusal bugs** (`t2t_extent_oob`, the sample-length
   equality) — both are small, evidence-backed, and cost content every boot.
7. **Treat the test suite as untrusted until it is deterministic.** 53–59 failures
   that move between runs cannot witness a regression; the depth and debt code has no
   test at all, and the formats patch's conversion arithmetic has none.
8. **Keep the investigation's reporting standard.** The instrument-first method,
   the counter names, and the fail-visible substitutions are the strongest part of
   this work; the defects above are almost all cases where a report or a gate was
   left behind by a later change (5.1, the malformed patch, the memo-era artifacts),
   which is the predictable cost of a fast-moving series.

---

# Addendum: fixes applied, and the first Star Birds cycle

## Fixes in the tree as of this run

New patch `packages/reims-vgpu/pr-assessment-fixes.patch` (applied last, after the
two diagnostics), plus two surgical edits to existing patches:

| Fix | Site |
|---|---|
| Five `resolve_sampled_source` test call sites get the 7th argument — the crate's test target compiles again | `runtime/draw/tests.rs` |
| `latch_linear_sample_mapping` decodes `page_entries` through `entry_gpa_shift` instead of comparing a raw entry with a GPA (the latch could never fire) | `runtime/draw/vulkan.rs` |
| `reissue_pending_stamps` writes the word on a `Settled` answer, through a shared `land_stamp_page` the publication path now uses too | `runtime/drain/mod.rs` |
| `store_action_publishes_single_sample(4)` and `store_action_in_contract(4)` agree with `StoreAction::parse(4) = Store` on the deferred ordinal | `protocol/pass_action.rs`, `runtime/draw/mod.rs` |
| `cpu_loader_arm_is_lossy` marks `Rgb10a2Unorm`/`Rg11b10Float` lossy, so the 64 KiB sampled floor stops silently narrowing HDR binds to 8 bits | `protocol/pixel_format.rs` |
| `unorm8_to_snorm_byte`'s doc now says `-127` (what the code does) | `protocol/pixel_format.rs` |
| `depth_resident_latest` gets a first-sight fail line naming the identity served | `runtime/draw/vulkan.rs` |
| Texture-to-texture bounds are block-aligned (`copy_available_extent`), so compressed mip tails copy instead of refusing; unit test added | `runtime/blit_exec/mod.rs`, `tests.rs` |
| `pr-render-target-formats.patch` no longer carries the two reverse hunks that deleted `pr79`'s `window_shortfall` guards | patch file |
| `pr-shader-draw-parameters.patch`'s doubled `context.rs` path fixed (git-applyable) | patch file |

Verification: the full series applies to the pinned revision in `default.nix` order and
reproduces the edited tree byte-for-byte; `reims-vgpu-protocol` 390 pass,
`reims-vgpu --lib backend::vulkan::translate` 35 pass, `blit_exec` 59 pass (including the
new block-extent test), full `reims-vgpu` lib suite 2180 pass / 54 fail — inside the
53–59 flaky band measured on the unmodified shipped tree.
Not yet fixed (deliberately left, see §5): the resolve-target participation
(`SetStoreAction` override does not reach the dependency graph), `R16Unorm`'s missing
CPU rails, and the `vk_draw_validate_guest_sample_length` exact-equality semantics.

## One Star Birds cycle (QEMU build before the fixes, appid 2719750)

Workflow: `run-game.sh <qemu> <tag>` → `ssh macos-vm 'steam_osx steam://rungameid/2719750'`
→ `spectacle -b -n -f` (host window) + `ssh … screencapture -x` (guest composite) →
log census → `ssh … sudo shutdown -h now`. Scripted as
`scripts/reims-game-test.sh`.

Reproduced: the Reims vGPU window is **completely black** while Steam and the game run;
the guest's own `screencapture` shows the desktop wallpaper with no game window. The
one-pass refusal census for that boot:

- `vk_slab_allocate_memory` **120×**, each preceded by
  `vram_pool_reclaim_retry released=13 held_bytes=16391340032` — the slab pool reports
  ≈16.4 GB held against a 16 GB guest, and the reclaim retry frees a handful of
  buffers. The refused passes are the scene's MSAA passes
  (`fmt=0x5c` RG11B10Float, `l2:s3` store-and-resolve, 1920×1080, `vtx=600`), and each
  becomes `draw_encode_fail class=no_metal` → `draw_fail_clear_fallback clears=0`, so
  the frame keeps its clear. This is the dominant cause in this boot.
- `fmt=0x69` = **`MTLPixelFormatRG32Float`** (8 bytes/texel: `bpr=15360` at 1920 wide)
  is not in the device's format table at all: refused as a render target
  (`rt_resolve reason=rt_linear_format`, 3×) and as a full-screen sampled source
  (`draw_prepare_texture_resolve_missing … reason=linear_sample`, so the composite that
  would put the scene on screen is skipped).
- `blit_fail reason=t2t_extent_oob` 112× — the compressed mip-tail refusal the
  block-aligned bounds fix addresses.
- `multisample_load_action_unsupported` 3× (`load=0x1 store=0x3`, non-continuing
  records) — the residual shape the MSAA patch deliberately still refuses.

Next steps for Star Birds: chase the 16.4 GB slab accounting (`vk_alloc_sites` by
format/geometry, resident population, and whether the newly admitted formats' residents
are ever reclaimed), then admit `RG32Float` with a full rail set the way the four Easy
Red 2 formats were admitted.

## Star Birds cycle 3 (fixed build, guest kept up): the black is a content/identity problem

The game reaches its **main menu** (`~/Library/Logs/Toukana Interactive/Star Birds/Player.log`:
`Set Cursor State by Scene: MainMenu`, music playing, v0.3.9e) and stays alive at ~11 % CPU
while the Reims window is black. This boot is **not** a refusal problem:

- `linux_m2v_draw ok` 7 156, `resident_chain` 3 992, `m2v_store_gva` 592,
  `host_window_publish published=12 dropped=0`,
  `host_window_cadence presents=11 direct=11 present_hz=9.6`, `host_window_loop draws_fresh=8`.
- Fail-channel refusals are 5 in the whole boot (`multisample_load_action_unsupported` 3,
  `vk_slab_allocate_memory` 2, `linear_sample` 1, `draw_prepare_pipeline_missing` 1) and
  `blit_fail` 0 — the fixes hold.
- Content: the stored frames are either uniform black (`rgb_nz=0`, 71 stores) or uniform
  white (546 stores of `tex_ref=2668` with `mean_rgb=255 max_rgb=255 rgb_nz=2073600`);
  a handful carry real content (`rgb_nz` ≈ 1.02–1.06 M).
- The guest's own `screencapture` is **not** a faithful observation on this rail: at the
  desktop phase (host window showing Steam, menu bar, dock) it returned two wallpaper
  panels and no windows. Only the host window capture is ground truth.
- The one piece of guest UI that *does* render in the host window is a WindowServer-drawn
  system dialog (my stray `xcrun` prompt) — so the present path and WindowServer's own
  drawing work; the composited desktop/game layers are what come out black.

The counters name the mechanism (last `store_routes` census):

```
sampled_direct_declined=1791        sampled_admit_no_identity=1796
wbdebt_texture_owes_nothing=2154    wbdebt_texture_owes_nothing_resolved=389
wbdebt_texture_owes_nothing_unresolved=1765
gva_resident_authoritative=260      gvarung_resident=533
chain_gva_debt_armed=13             chain_resident_debt_armed=15
```

`wbdebt_texture_owes_nothing_unresolved` is the counter §2.7 of the investigation used
for the black window: a sampled bind asked whether the surface it reads owes a writeback,
and the ledger answered "nothing owed" 1 765 times, so the read falls to guest pages that
no Store published. The composite runs as `sampled_full_screen_consumer pipe=281
ref=213/255/256 src_mid=14/22/30 target_mid=1/4 route=guest_runs` — i.e. WindowServer's
composite reads **mapping-keyed** surfaces (`src_mid`), while the game renders into
**GVA-keyed** targets (`chain_gva_debt_armed`, `gva_resident_authoritative`,
`mid=0`). The debt was armed under the GVA identity and looked up under the mapping
identity, so the lookup resolves nothing. That is the mapping↔GVA half of the same
identity split §2.7/§2.8 fixed for the chain and cross-task directions; the next fix
belongs there, not in a new format.

Next diagnostic (one boot, no code): `REIMS_VGPU_DIAG_CHAIN_READBACK=1` prints
`diag_chain_target`/`diag_sample_probe` with the target's gva and the debt at the bind's
address, which joins the two names and proves (or falsifies) the shared-allocation claim
before the bridge is written.

## Star Birds cycle 4 (diag probes): the debt is armed only for the Gva namespace

Boot with `REIMS_VGPU_DIAG_CHAIN_READBACK=1`, game at the menu, one pass over the probes:

```
diag_chain_target  62 lines   (chain targets the render side produced)
chain_gva_debt_armed  8–10    (how many of them armed a writeback debt)
diag_sample_probe  152 lines, every one `debt=None`
wbdebt_texture_owes_nothing_unresolved = 1380
```

The join is direct: `diag_chain_target task=2 ref=2666 gva=0x35184000 fmt=0x5c 1920x1080`
(t=33639) and `diag_sample_probe task=2 ref=2666 fmt=0x5c 1920x1080 gva=0x35184000
debt=None` (t=33690) — the *same* task, ref, address and format, rendered as a chain
target and 51 ms later sampled with nothing owed at that address. All 152 probes answer
`debt=None`, not just the cross-named ones.

The gate is one function. `pr-chain-gva-writeback-debt` arms the ledger only when
`crate::backend::vulkan::gva_window(&identity)` is `Some`, and `gva_window`
(`backend/vulkan/mod.rs:135–151`) answers `Some` **only** for
`TargetIdentity::Gva { .. }` and `None` for every other namespace. Most of this game's
chain targets resolve to a texture-keyed identity (the resident is right, the namespace
is not), so they skip the arm while still carrying a non-zero `target_gva` on the color
attachment. The compositor then samples those surfaces through guest pages
(`sampled_full_screen_consumer … src_mid=… route=guest_runs`), finds no debt, and reads
pages no Store published — the black window, with the device drawing 7 000+ times.

The fix is therefore in the arm, not in a format: arm the debt from the color
attachment's own `target_gva`/geometry (and the resident's generation, or the `0` a
texture-keyed identity already uses) whenever `target_gva != 0`, instead of requiring
the identity to be in the `Gva` namespace. `diag_chain_readback` succeeded for only 10 of
the 62 chain targets, so the resident-readback path is limited by the same gate.

## Star Birds cycles 5–6 (present dump): the device's own frames are black

The present-dump diagnostic (`REIMS_VGPU_PRESENT_DUMP=<dir>`, temporary patch
`pr-diag-present-dump.patch`) writes the resident the host window is about to present as
a P6 PPM. That is the witness the counters could not give.

- **Boot/desktop phase: the device's frames are perfect.** Dumps of `Surface { id: 2/4/6 }`
  show the wallpaper, menu bar, dock and the Steam window, `rgb_nz≈2.03M max_rgb=255`.
- **Game phase: the device's frames are black.** The dumps become `rgb_nz=0 max_rgb=0`
  or `rgb_nz=2073600 max_rgb=4` — a full 1920×1080 frame whose brightest channel is 4/255
  — for the surfaces the guest presents (`Surface { id: 11/13/39 }`, generation counts
  into the teens). Rendered to PNG, they are the black window.
- So the black is **not** the window's blit, not a stale present, and not the debt
  lookup: the device itself presents black frames. (The reader-side aliasing experiment
  above fired only 3× in a whole boot, so it is not the mechanism; it stays as a
  conservative correctness change, not a fix.)

The refusal lines name the pass that would have put the scene there:

```
linux_m2v_draw reason=draw_prepare_texture_resolve_missing stage=fragment index=0
  texture_ref=2546 detail=…_fmt=0x69_mips=1_…_L0=1920x1080_bpr=15360_reason=linear_sample
  pipe=2616 task=2 geom=1920x1080 vtx=3 inst=1 prim=3 first=0 idx=0
  colors=[s0:r2602:mid0:gva=0x29add000:1920x1080:fmt=0x5c:l0:s3]
linux_clear_store draws_skipped … refused_by=draw_prepare_texture_resolve_missing mid=0
  gva=0x29add000 1920x1080 load=0x1 store=0x3 clear=[0.000,0.000,0.000,1.000]
rt_resolve reason=rt_linear_format base=… fmt=0x69 task=9 …
```

`fmt=0x69` is **`MTLPixelFormatRG32Float`** (`bpr=15360` at 1920 wide = 8 bytes/texel).
The chain is complete and every link is evidenced:

1. The game's scene pass renders into an RG32Float target — refused as a render target
   (`rt_linear_format`), so the target never receives the scene.
2. The game's full-screen composite (pipe 2616, `vtx=3`) samples that RG32Float texture —
   refused as a sampled bind (`linear_sample`), so the composite that would write the
   game's final HDR frame is skipped (`draw_fail_clear_fallback clears=0`).
3. WindowServer's composite (pipe 30, sources `src_mid=2/3/4/7`, targets
   `target_mid=11/13/39`) then composites an empty window correctly onto the display
   surfaces, and the device presents them — black, at `max_rgb=4`.

The device has **no rail at all** for `RG32Float`: no constant, no `TexelLayout`, no
`SampledClass`, no render-target numeric class, no store order. It is the same class of
gap the four Easy Red 2 formats had, and it needs the same treatment: a `Rg32Float`
layout (8 bytes/texel, float class, Vulkan `R32G32_SFLOAT`), a sampled class and the
sampled/linear maps, render-target admission with `store_texel_order` for the byte copy,
CPU narrow/expand/row arms (lossy — two f32 channels into eight bits), the compute
sampled class, and the test tables. Estimated footprint: the four files
`pr-render-target-formats.patch` touched (protocol `pixel_format.rs`,
`reims-vgpu-vulkan/src/pixel.rs`, `runtime/backend/vulkan/translate/pixel.rs`,
`runtime/compute_exec/vulkan.rs`) and roughly the same number of hunks.

## Star Birds cycle 7 (RG32Float admitted): content comes back; one pass class left

`pr-rg32float.patch` admits `MTLPixelFormatRG32Float` (0x69) with the rail set the four
Easy Red 2 formats have: a `TexelLayout::Rg32Float` (8 bytes/texel, float numeric class,
render-target mask, `store_texel_order` for the byte copy, **no** CPU arm — the
`R32Float` precedent, since the native copy is the guest's own word), a
`SampledClass::Rg32Float` with the sampled/linear maps against
`vk::Format::R32G32_SFLOAT`, and the sampled-image-only compute class. One structural
change came with it: the capability snapshot's `u64` word was **full**, so its dimension
field narrowed from 32 bits to 16 (a Vulkan `maxImageDimension2D` is at most 32768, and
the layout/filter masks are exactly what their readers ask about), with an assert
replacing the silent truncation.

Verification: `reims-vgpu-protocol` 390 pass, `reims-vgpu-vulkan` 629 pass (+5, +8 aux),
runtime compiles, full lib suite 2179/55 inside the pre-existing flaky band. One cycle on
the new build:

- `rt_resolve reason=rt_linear_format` for `fmt=0x69`: **0** (was 3).
- `draw_prepare_texture_resolve_missing` / `reason=linear_sample`: **0** (was 1).
- `vk_slab_allocate_memory` 0, `blit_fail` 0.
- The host window is no longer wholly black: with Star Birds launching, the Steam client
  window renders in full colour inside the Reims window (it was black in every earlier
  cycle), so the composite pipeline that was broken by the missing format is working.

What remains, from the same boot's census, is one class of pass:

```
linux_clear_store draws_skipped refused_by=multisample_load_action_unsupported pipe=2755
  vtx=6  mid=0 gva=0x374a6000 1920x1080 load=0x1 store=0x2 clear=[0,0,0,1]
linux_clear_store draws_skipped refused_by=multisample_load_action_unsupported pipe=2784
  vtx=3  mid=0 gva=0xb49000   1920x1080 load=0x1 store=0x3 clear=[0,0,0,1]
linux_clear_store draws_skipped refused_by=multisample_load_action_unsupported pipe=2619
  vtx=3  mid=0 gva=0x1332000  1920x1080 load=0x1 store=0x3 clear=[0,0,0,1]
linux_clear_store draws_skipped refused_by=multisample_load_action_unsupported pipe=2616
  vtx=3  mid=0 gva=0x2c75b000 1920x1080 load=0x1 store=0x3 clear=[0,0,0,1]
```

These are **full-screen** MSAA resolve passes (3- and 6-vertex draws into 1920×1080
targets, store 2/3, black clears) — `pipe=2616` is the very composite the RG32Float
admission unblocked one stage earlier, so it now gets past the texture resolve and is
refused at the multisample LOAD check. `pr-msaa-store-and-resolve.patch` admits LOAD only
when `req.continues_render_pass`, and these records are the *first* record of their packet
even though the engine's single multisample slot may well still hold the same key's
content (the slot is reused when `slot.key == key && !key.transient_depth`, and key
equality does not require packet continuity).

The honest fix is therefore an **engine** change, not another predicate widening: choose
the pass's load op from the slot's liveness — CLEAR when
`acquire_multisample_target` will create a fresh image, LOAD when it reuses the live one.
That means computing the `MultisampleTargetKey` before the `PassKey`'s `color0_load` is
fixed, or re-fetching the pass once the acquisition has answered. Accepting LOAD
unconditionally is not equivalent: a fresh slot would begin with `initialLayout =
UNDEFINED` and load undefined contents, which is harmless for a full-screen overwrite but
not for a partial pass. That decision — whether the device may load an undeclared scratch
image when the guest asks — is the one the patch's own comment says stays refused, so it
belongs to the maintainer rather than to a diagnostic round.

## Star Birds cycle 8 (MSAA load from slot liveness): **the menu renders**

The last blocker was the MSAA load contract, and it is fixed the way §"cycle 7" said it
should be, not by widening the predicate:

- `pools::multisample_slot_is_live` is now the one predicate the acquisition's reuse check
  and the pass choice both call, so they cannot drift;
- `execute_draw_request` re-fetches the MSAA pass with `color0_load = Clear` when the
  record declares `Preserve` and the slot is not live — asked where the key exists,
  because the resolve and depth views it names are resolved above the point the pass is
  first chosen. A live slot keeps the load; a fresh one begins with a defined clear
  instead of loading an image created `UNDEFINED`;
- the runtime no longer refuses the record.

Also folded into the RG32Float patch: the engine's own `EXPECTED` format table, which the
first cut missed (`the_engine_rails_accept_exactly_these_formats` caught it).

One cycle on the new build (`9z9llyq0…`):

```
draw refusals: multisample_load_action_unsupported  0   (was 4)
               vk_slab_allocate_memory              6
               draw_prepare_pipeline_missing        1
present_dump:  30 of 38 frames carry content (rgb_nz 747 005 … 2 073 600, max_rgb 255)
               the 8 black ones are the pre-paint frames of the display swapchain
```

And the host window shows **the Star Birds main menu** — the logo, `Continue`, `Level
Selection` — where every previous cycle showed black. Screenshot:
`/tmp/opencode/shots/msaa-1-host.png` (crop `msaa-1-crop.png`).

Remaining, unrelated to the menu: `vk_slab_allocate_memory` pressure (6 this boot, the
16.4 GB class from cycle 3) and one `draw_prepare_pipeline_missing`. Both are the
already-open items, not blockers for the menu.

## Star Birds cycle 9 (iGPU rail): the memory ceiling, answered

Two things were settled by one cycle on the integrated GPU plus the guest's own report.

**The guest's GPU is a 64 MB paravirtual device.** `system_profiler SPDisplaysDataType`
inside the guest:

```
Chipset Model: Apple Paravirtualized Graphics Device
VRAM (Total): 64 MB
Vendor: Apple (0x106b)   Device ID: 0xeeee   Metal Support: Metal 2
```

So macOS puts essentially every resource in *guest RAM*, and the device imports those
pages as host pointers (the `host_ram_import … heap_mb=47695` lines). The guest's VRAM
number is not the constraint and never was.

**What actually runs out is the device's own host-side image pool against the host GPU's
heap.** On the discrete 5080 (`device_local_mb=16303`) the device's slab reported
`held_bytes=16 382 951 424` (≈15.26 GiB, ~96 % of that heap) with **1 685**
`vram_pool_reclaim_retry` events whose `released=` was 0–112, and `vkAllocateMemory`
itself began failing (`vk_result=A_device_memory_allocation_has_failed`) on the game's
1920×1080 passes. `held_bytes` is `slab.rs`'s sum of block *plan* sizes, so treat the
figure as the device's own accounting rather than a driver reading — but the failures were
real, and on the integrated GPU, whose heap is unified and 46.6 GB
(`vk_caps memory=unified device_local_mb=47695`), the same workload recorded:

```
vram_pool_reclaim_retry        0          (was 1 685)
linux_m2v_draw reason=…        1 × draw_prepare_pipeline_missing  (was ~1 700 slab refusals)
nvidia-smi memory.used         2 MiB, 0 % util   (the rail is not on the 5080)
```

So: not the VM's RAM, not the guest's 64 MB, and not nvidia-smi's figure during an idle
host — the device allocates its own images from the host GPU's heap, and the 16 GB
discrete heap is what it filled. The iGPU route removes the failure class entirely.

**The remaining artifacts are pre-existing, and not the rail.** The user reports the
tearing band on the NVIDIA rail as well, before any of this session's changes. A burst of
window captures plus the 40 present dumps measured with a row-discontinuity metric show
both the device's frames and the window's frames internally smooth (median row-diff
0.24–0.70) with discontinuities only at fixed content edges (rows 23/89/889/1074, the same
in every dump) — no torn frame is present in the dumps sampled, so the tear is transient
and animation-dependent, and the present dumps' 40-frame cap was reached during boot
before the interesting part of the session. Catching it needs a temporal witness (compare
each presented frame against the previous one) rather than a single-frame measure.
`present_black` fired 4 times this boot (1 of the 40 dumps was black), which is the
"black flash" class the earlier cycles also saw.

## Star Birds cycle 10 (fresh-attachment clear): the red was the guest's wallpaper

One cycle on the integrated rail with `REIMS_VGPU_VK_DEVICE_TYPE=integrated` and the
present dump on, aimed at the launch transition rather than a single frame (a 40-frame
host burst plus the dumps).

**The fix.** A record that declares a preserving load (`MTLLoadActionDontCare`) and
arrives with nothing this device can offer was begun with `DONT_CARE` over `UNDEFINED`,
which over a freshly created image means the pass presents whatever the pool's memory
last held. `slot0_begin` now asks the registry (`content_ready`, the same bit that
decides whether a `LOAD` is answerable) and gives the stale case a defined clear, while
an attachment that does hold the guest's own earlier output keeps the `DONT_CARE`
reading — the invariant `caches.rs`'s four `color0_load_tests` assert, untouched, since
clearing there is the author's measured 461 draws / 2 107 399 texels of live guest
content. The witness says the case is real and how often:

```
color0_preserve_unhonoured   51   (one boot; first-sight lines name Gva 256×256 and
                                   Gva 93×93 colour residents, all elected=Clear)
```

**The red is not stale content, and this is the correction.** The change was written up
as the fix for a red overlay the dumps appeared to show (full-frame `red_rows=1003/1080`
at present 320, breaking into 5→15 bands, `mean=(228,139,59)` — the orange the user
described where red met the ocean). Reading the resident the window actually presented
and *looking at it* settles it: `dumps-fresh/present-dump-3.ppm` is macOS 13's own
Ventura wallpaper (the orange/red swirl) with Steam's "Updating Steam… Verifying
installation…" sheet over it and the Dock below. The pre-fix dumps show the same image
at the same presents. So the red bands are the guest's desktop, presented correctly, and
no visible defect was ever caused by the load-op case — the code comments and
`default.nix` now say so instead of claiming an artifact.

**What this cycle did not test.** Steam was updating itself for the whole window
("Verifying installation…"), so the title never reached its menu: 8 pipeline
declarations, 1 `draw_prepare_pipeline_missing`, and the last dump still the desktop.
The game path — menu, 3D artwork, the scene pass — was not exercised, and the
`REIMS_VGPU_PRESENT_DUMP` sampling (`call % 256`, 40 dumps ≈ 10 000 presents) spent its
six dumps on boot and the desktop.

**Method note, worth keeping.** The per-row census that "found" the artifact cannot tell
the guest's own red wallpaper from stale red rows; both are rows of red-saturated mean.
The metric was right and the conclusion drawn from it was wrong. Only the pixels
themselves distinguish them, so a colour census is a *locator* (it says which frames to
open) and never a verdict.

**Still open, unchanged by this cycle.** The user-visible red biting into the game's
frame and mixing with the ocean's blue into orange, which the user also saw on the
NVIDIA rail before any of these changes; the missing 3D artwork in the menu (cycle 8 got
the menu to render, the scene geometry is still refused or absent); `present_black`
(2 this boot); and the three temporary diagnostics that must come out before anything is
offered upstream.

