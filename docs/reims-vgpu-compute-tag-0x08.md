# Upstream report: compute pipeline tag `0x08` refused — Unity games render black

Status: **fix verified in a patched build** (see Verification). This file is the
issue text and the PR description; the patch is
`packages/reims-vgpu/pr-threadgroup.patch` in this repo (also applied to the
build), generated against `69a57dd69a6958e946c03b73e02db331f330f435`.

---

## Issue

**Title:** x86/Vulkan: compute pipeline descriptor carrying tag `0x08`
(`maxTotalThreadsPerThreadgroup`) is refused — Unity games render black

### Summary

On the x86_64 Linux/KVM `reims-vgpu-pci` Vulkan pathway, Unity 2022.3 games
launch (menu music plays, window presents at ~59 Hz) but render a **black
screen**. The device log shows the cause: every compute pipeline the game
builds is refused by the decoder.

```
compute_load_pipeline fail reason=desc_decode task=11 pipe_ref=314 desc_len=60
```

993 496 occurrences in one session. The game's compute kernels are
`Internal-Skinning.main` and `Internal-BlendShape.main` — Unity's GPU skinning
and blend-shape kernels — and every draw that used one of those pipelines was
refused, so the canvas never rendered while the audio path (CoreAudio) was
unaffected.

### Environment

- Host: NixOS 26.11, kernel 7.2.4, KVM, NVIDIA RTX 5080 Laptop, driver
  595.99.02, Vulkan backend.
- Guest: macOS 13.7.8 (22H730) x86_64, 8 vCPU, 16 GiB, `reims-vgpu-pci`.
- reims-vgpu `69a57dd6`, QEMU submodule `bd88218d`, QEMU 11.0.50.
- The host build additionally carries the in-flight fixes from PRs #81 and #79
  (guest-write release ordering), which are not related to this defect.
- Game: Easy Red 2 v2.1.0, Unity 2022.3.62f3.

### The descriptor

A temporary dump of the refused bytes (60 bytes, from the live guest):

```
0b000000 3c000000 31010000 2a000000 03020413 00000008
04400000 00000476 00000049 6e746572 6e616c2d53 6b696e6e
696e672e 6d61696e 000000
```

Decoded as the compact-TLV grammar this decoder already reads:

| Offset | Field |
|---|---|
| `+0x00` | `0x0b` — `SERIALIZER_OBJECT_COMPUTE_PIPELINE` |
| `+0x04` | `0x3c` — declared length, 60 |
| `+0x10` | field count 3 |
| field 1 | tag `0x02` (label), len 4, value 19 → the name string at `+35` |
| field 2 | **tag `0x08`, len 4, value 64** — unidentified |
| field 3 | tag `0x00` (kernel function), len 4, value 118 |
| `+35` | `Internal-Skinning.main` |

`note_pipeline_tlv_fields` refuses any tag that is neither consumed
(`0x00`, `0x03`) nor benign (`0x01`, `0x02`) on a compute descriptor — by design,
because applying Metal's default to an unidentified property is the silent
modification `PipelineFieldDropped` exists to stop. Tag `0x08` is simply not
identified yet.

### Identifying the tag

The method this file's render list already documents: set exactly one property
on a bare `MTLComputePipelineDescriptor` and read what Apple's own serializer
emits. Run in the guest over SSH, no compiler needed:

```js
// osascript -l JavaScript probe.js
ObjC.import("Metal"); ObjC.import("Foundation");
var dev = $.MTLCreateSystemDefaultDevice();
var sel = $.NSSelectorFromString("serializeComputePipelineDescriptor:");
function ser(d) { return ObjC.unwrap(dev.performSelectorWithObject(sel, d).description); }
var d = $.MTLComputePipelineDescriptor.alloc.init;
console.log("baseline: " + ser(d));
d.maxTotalThreadsPerThreadgroup = 64;
console.log("maxTotalThreads: " + ser(d));
```

```
baseline:         {length = 1, bytes = 0x00}
label:            {length = 19, bytes = 0x0102040700000070726f62652d6c6162656c00}
tgMultiple:       {length = 7,  bytes = 0x01010401000000}
maxTotalThreads:  {length = 7,  bytes = 0x01080440000000}   <-- tag 0x08
icb:              {length = 7,  bytes = 0x01070401000000}   <-- tag 0x07
maxCallStackDepth:{length = 1,  bytes = 0x00}
```

So, for `MTLComputePipelineDescriptor`:

| Tag | Property |
|---|---|
| `0x00` | `computeFunction` (consumed) |
| `0x01` | `threadGroupSizeIsMultipleOfThreadExecutionWidth` (benign) |
| `0x02` | `label` (benign) |
| `0x03` | `stageInputDescriptor` offset (consumed) |
| `0x07` | `supportIndirectCommandBuffers` — **also unidentified; not fixed here** |
| `0x08` | **`maxTotalThreadsPerThreadgroup`** — this issue |

`maxCallStackDepth` emitted nothing (the property serializes as absent in this
shape).

### Why tag `0x08` is benign on this rail

Core Vulkan has no per-pipeline invocation limit to apply, so the device builds
the pipeline from the kernel alone and takes the threadgroup shape from the
dispatch record — the same place the guest's own dispatch gets it. The property
can only *lower* a pipeline's cap, so a guest that honours it dispatches at or
below it and nothing changes, and a guest that does not is one whose pipeline
creation on Metal would have failed first. The device limit that does matter is
the one `compute_info_caps` answers, and that one is read from the host.

### Note on the existing doc

`decode_render_pipeline_descriptor`'s doc records an earlier draft's guess that
the compute pair might include `maxTotalThreadsPerThreadgroup` and says the
alarm was wrong. The guess was right about the property and wrong about where it
lives: it is tag `0x08`, and the wire carries four bytes. The patch updates that
paragraph rather than deleting it.

### Tag `0x07` (`supportIndirectCommandBuffers`) is a separate question

The same probe identifies it, but it should not join the benign list: the Metal
rail's ICB support requires the compute PSO to be built with
`supportIndirectCommandBuffers`, so dropping the tag is rail-dependent work, not
a documented non-application. Flagged here so the next report does not have to
re-identify it.

---

## Patch (PR description)

**Title:** decode: `maxTotalThreadsPerThreadgroup` is compute tag `0x08`, and it
is benign on the Vulkan rail

Three changes in
`crates/reims-vgpu/src/runtime/decode/resource/mod.rs`:

1. `COMPUTE_PIPELINE_TAG_MAX_TOTAL_THREADS: u8 = 0x08` with the serializer-probe
   evidence in its doc.
2. `COMPUTE_PIPELINE_TAGS_BENIGN` grows to three entries with the argument for
   the new one beside it, per the list's own rule.
3. The "earlier draft" paragraph now records the identification instead of a
   disproof.

And one regression test in `.../decode/resource/tests.rs`: the live 60-byte
record from the game, asserting it decodes, that the kernel ref is `0x76`, that
the label's string is not read as a stage-input section, and that no
`pipeline_descriptor_field_dropped` line is emitted for a benign tag.

Verification: the full Vulkan test suite for the crate (see the patch's own
test), plus a live boot of the game that produced the record.

---

## Verification

| Step | Result |
|---|---|
| `cargo check -p reims-vgpu --tests --no-default-features --features backend-vulkan,host-window` | **passes** |
| Live boot, Easy Red 2 launched | `desc_decode` count frozen at 1,563,730 (no new refusals); `compute_pipeline_hits=62`, `dispatches=62` — the game's compute pipelines now build and run |
| Screen | **still black** — see the second blocker below |

## Second blocker found while verifying: a metal2vulkan kernel refusal

With the tag fix in, the game's compute pipelines build and dispatch, the window
presents 60 fresh frames/s and 61 full-screen draws/s execute — and the screen is
still black. The only live failure left in the boot is one compute kernel the
translator refuses:

```
compute_record reason=compute_vk_translate class=metal_failed task=7 pipe=301 kind=DispatchThreadgroups
linux_m2v reason=m2v_kernel_translate stage=kernel
  detail=native_emitter:_owned_Store_violates_its_pointer-pointee_and_value-type_contract
```

That message is `metal2vulkan`'s native emitter
(`src/native/owned_cfg.rs`, `owned_memory_type_error`): for an owned `Op::Store`
it requires the stored value's SPIR-V type id to be **exactly equal** to the
pointer's pointee type id. The game's kernel has a store where they differ, so
the kernel never becomes a `VkPipeline` and the dispatch fails — the frame stays
black while audio runs.

Everything after that refusal is clean: no declines, draws execute, frames
present.

Status: reproducing through metal2vulkan's own harness
(`examples/translate_native`, which replays a sanitized AIR `.ll` through the
native emitter and runs `spirv-val`). The AIR is being captured from the device
with `REIMS_VGPU_AIR_CAPTURE=on` plus a temporary on-failure dump in
`m2v_cache::translate_kernel_air`. Once the exact store is in hand this is
either an emitter type-dedup gap (two ids for one canonical type) or a real
compatibility rule the check is missing; the fix belongs in metal2vulkan, and a
second issue/PR will follow.

## How to post

No `gh` CLI or GitHub credentials on this host. To file it:

```sh
# from a clone of the upstream repo, on the pinned base
git checkout -b fix/compute-tag-08-max-total-threads 69a57dd6
git apply /home/tianyixia/nixos-config/packages/reims-vgpu/pr-threadgroup.patch
git commit -am "decode: maxTotalThreadsPerThreadgroup is compute tag 0x08, and it is benign on the Vulkan rail"
git push -u origin HEAD
```

Then open the PR with the description above, and the issue with the issue
section (they can be one PR if you prefer; the issue is the evidence, the PR is
the change).
