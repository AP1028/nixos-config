# Upstream report: Vulkan rail refuses a draw whose guest sampler bind cannot be resolved

Status: **fix built and in the boot image; driven verification pending** (see
Verification). This file is the issue text and the PR description; the patch is
`packages/reims-vgpu/pr-sampler-fallback.patch` in this repo (also applied to
the build), generated against `69a57dd69a6958e946c03b73e02db331f330f435`.

---

## Issue

**Title:** x86/Vulkan: one unresolvable guest sampler bind refuses the whole
draw — every full-screen composite is lost and the screen stays black

### Summary

On the x86_64 Linux/KVM `reims-vgpu-pci` Vulkan rail, a render record whose
sampler slot names a ref the sampler resolver cannot answer is refused as a
whole. In a driven Easy Red 2 (Unity 2022.3) session that cost the frame:

```
linux_m2v_draw reason=draw_prepare_sampler_no_list_entry sampler_ref=313 binding=160 pipe=30 task=1 geom=1920x1080 vtx=6 ...
linux_clear_store draws_skipped reason=draws_skipped_after_engine_refusal pipe=30 model_pipeline=ready vtx=6 refused_by=draw_prepare_sampler_no_list_entry mid=35 gva=0x0 1920x1080 load=0x1 store=0x1 clear=[0.000,0.000,0.000,1.000]
exec_indirect2 ch=1 task=0 streams=0 saw_draw=1 clears=0 draws_ok=0 draws_fail=1 ...
```

**661 of 692 draws were refused** in the session; **639 command buffers held
exactly one draw and it was the refused one** — a full-screen six-vertex
composite (`pipe=30`) that samples the game's finished frame texture
(`sampled_full_screen_consumer pipe=30 ref=335 src_mid=43 src=1920x1080
target_mid=35 target=1920x1080 vtx=6`) and stores it into the drawable. The
present path for that drawable is `present_route route=clear_only
write_kind=ClearOnly`, so with the composite refused the drawable stays at its
black clear: **audio plays, the window presents at 60 Hz, and the screen is
black.**

### Environment

- Host: NixOS 26.11, kernel 7.2.4, KVM, NVIDIA RTX 5080 Laptop, driver
  595.99.02, Vulkan backend.
- Guest: macOS 13.7.8 (22H730) x86_64, `reims-vgpu-pci`.
- reims-vgpu `69a57dd6` plus the in-flight PRs #81/#79 and two local fixes
  (compute tag `0x08`, and a metal2vulkan scalar-store lowering); the session
  log above is otherwise clean of translation and decode refusals.
- Game: Easy Red 2 v2.1.0, Unity 2022.3.62f3, `FullScreenWindow` 1920x1080.

### Root cause

`runtime/draw/vulkan.rs`, inside `try_metal2vulkan_draw`'s sampler
provisioning:

```rust
if sampler_binds.insert(smp_bind) {
    let mut sampler = if sampler_ref != 0 {
        sampler_origin.insert(smp_bind, b'g');
        load_vulkan_sampler(state, host, req.task_id, sampler_ref, smp_bind)
            .map_err(DrawError::DrawPreparation)?
    } else {
        sampler_origin.insert(smp_bind, b'd');
        SamplerResource::normalized_default(smp_bind)
    };
```

A nonzero `sampler_ref` that the resolver cannot answer — `NoListEntry` (the
ref is not in the task's object list) or `WrongType` (it is there and is not a
serializer object) — becomes a `DrawError` and the whole record is refused. The
refusal also **claims the binding** (`sampler_binds.insert` happens before the
load), so the reflected-sampler loop that runs afterwards — which knows the
binding's real answer, the shader's own `static_state` sampler when it has one
and the normalized default otherwise — never gets to provision it.

The macOS rail has always handled this case the other way, in
`runtime/draw/metal/mod.rs`:

```rust
// Samplers: serializer-object subtype 0x03 when present. A nonzero ref is an explicit
// guest bind; if it cannot be resolved, keep the correct fallback but make
// the degradation visible with the exact resolver reason.
let sampler = load_sampler(state, host, req.task_id, s.sampler_ref, s.index)
    .unwrap_or_else(|error| {
        crate::observe::Emit::decline("metal_draw_sampler_fallback", &error) ... ;
        default_sampler(REIMS_VGPU_BINDING_SAMPLER_BASE + s.index)
    });
```

That asymmetry is the defect: the same guest bind is a one-line degradation on
one rail and a lost frame on the other. The metal rail's `fail_once` key never
fired in this session (`metal_draw_sampler_fallback` count: 0) because the
session is on the Vulkan rail; the Vulkan rail's own decline was emitted only
three times, because the draw tail dedupes on `(pipeline, slug)` while the
skipped-draw line counts every frame.

The refs themselves are not samplers. In the same log, ref 313 is a sampled
texture (`sampled_ref_backing task=1 ref=313 view=1920x1080 mid=2
map=1920x1080 map_fmt=0x50 route=guest_runs`) and ref 344 is
`OBJECT_TYPE_REF_TEXTURE` (object type 5) — the guest's sampler slot is not
naming a serializer-object sampler. Whatever the guest means by it, it is not a
reason for the device to drop a frame it can otherwise draw: the shader's own
static sampler is the answer for that binding, and the default is the answer
when it has none.

### Proposed change

Treat an unresolvable guest sampler bind the way the macOS rail already does:
report it once (`linux_m2v_sampler_fallback`, with the resolver reason and the
task/pipeline/stage/ref/binding), release the binding claim, and let the
reflected-sampler loop provision it. No sampler is invented: the binding gets
exactly the resource it would have gotten if the guest had bound nothing.

### Verification

- `cargo check -p reims-vgpu --no-default-features --features
  backend-vulkan,host-window` passes.
- Driven session, before: `draws_ok=31 draws_fail=661`, 639 single-draw
  command buffers with `draws_ok=0 draws_fail=1`, screen black.
- Driven session, after: *pending — filled in when the boot image is tested.*
  The counters to read are the `draws_ok`/`draws_fail` pair on `exec_indirect2`
  and the `linux_m2v_sampler_fallback` line, which should appear once per
  `(ref, binding)` with `sampler_origin` reported as `c` (static) or `d`
  (default) rather than `g`.

## PR

**Title:** vulkan: degrade an unresolvable guest sampler bind instead of refusing the draw

Body: the Summary, Root cause, Proposed change, and Verification sections
above.

## How to post

No `gh` CLI or GitHub credentials on this host. To file it:

```sh
# from a clone of reims-vgpu, on the pinned base
git checkout -b fix/vulkan-sampler-bind-fallback 69a57dd6
git apply /home/tianyixia/nixos-config/packages/reims-vgpu/pr-sampler-fallback.patch
git commit -am "vulkan: degrade an unresolvable guest sampler bind instead of refusing the draw"
git push -u origin HEAD
```

Then open the PR with the description above and the issue with the issue
section.
