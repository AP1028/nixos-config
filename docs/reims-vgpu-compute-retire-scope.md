# Upstream report: the CPU-visible compute path quiesces the whole device on the packet thread

Status: **fix built and booted; driven verification pending** (see
Verification). This file is the issue text and the PR description; the patch is
`packages/reims-vgpu/pr-compute-retire-scope.patch` in this repo (also applied
to the build), generated against `69a57dd69a6958e946c03b73e02db331f330f435`.

---

## Issue

**Title:** x86/Vulkan: a compute dispatch with a CPU-visible output quiesces the
whole device on the packet-processing thread — guest Metal calls then block in
the kernel for minutes

### Summary

`execute_compute_inner` calls `pools.retire_all` whenever the dispatch has
anything to hand the CPU (a writable storage buffer readback, a storage-image
readback, or a direct guest-window write). `retire_all` is a **full device
quiesce**:

```rust
pub(crate) unsafe fn retire_all(&mut self, ctx, counters) -> Result<(), DrawError> {
    self.batch_flush(ctx, counters)?;                      // submit the tail batch
    for index in 0..self.slots.len() {
        self.retire_slot(ctx, counters, index)?;           // waits that slot's fence, up to 5s
    }
    let still_open = self.open_slot_mask();
    self.release_graveyard(&ctx.device, !still_open);      // sweep everything eligible
}
```

and it runs on the **packet-processing (drain) thread**. So a compute dispatch
that needs one fence waits every ring slot's fence first — including the slots
the *draw* path is using for the desktop's composites — with `FENCE_TIMEOUT_NS`
(5 s) each, and then sweeps a graveyard that is not its subject. While it does,
guest packets are not processed at all.

In a driven Easy Red 2 (Unity 2022.3) session every skinning/blend-shape
dispatch carries a CPU-visible output, so every dispatch took the quiesce. The
session's device log stopped advancing for minutes at a time while the process
stayed alive, and the guest hung:

```
guest:  UnityGfxDeviceWorker → -[MTLIOAccelBuffer dealloc]
          → -[MTLIOAccelResource dealloc] → ioAccelResourceFinalize
          → IOConnectCallMethod → mach_msg2_trap        (waits, forever)
device: execute_compute_inner → retire_all → retire_slot → release_graveyard
          (host gdb, both rails: NVIDIA blocked in poll() inside libnvidia-glcore,
           Intel blocked on a futex inside the driver's free path)
```

Unity's main thread then waits on its render thread's semaphore, the window
stays black, and the guest's kernel call never returns even after the device
recovers — there is no timeout on that side.

### Environment

- Host: NixOS 26.11, kernel 7.2.4, KVM. Reproduced on **both** host GPUs —
  NVIDIA RTX 5080 Laptop (driver 595.99.02) and Intel Arc (ARL) iGPU — which is
  what rules the host driver out.
- Guest: macOS 13.7.8 (22H730) x86_64, `reims-vgpu-pci`.
- reims-vgpu `69a57dd6` plus three in-flight local fixes (compute tag `0x08`,
  metal2vulkan scalar-store lowering, Vulkan sampler-bind fallback). With those
  in, the session has **no** translation, decode, sampler or texture refusals,
  all 143 compute pipelines build (`compute_pipeline_hits=143, misses=0`), the
  full-screen composites resolve and draw, and the window presents at 20–30 Hz.
- Game: Easy Red 2 v2.1.0, Unity 2022.3.62f3, `FullScreenWindow` 1920x1080.

### Root cause

The wait a readback needs is the fence of **its own** submission. `retire_all`
answers a different question ("is the whole device idle?") and pays for it with
every other in-flight submission, on the one thread whose job is to keep guest
packets moving.

The housekeeping `retire_all` performs is not lost without it: the device
already runs the same retire on the poll heartbeat
(`advance_graveyard_maintenance` → `retire_signaled_slots`, which never waits on
an unsignalled fence) and every `begin_entry` retires already-signaled slots.

### Proposed change

Add `ResourcePools::retire_compute_entry` — flush the tail batch, then retire
**only `self.cur`**, the slot the entry was sealed into
(`finish_entry_async` parks cleanup there and `batch_flush_inner` uses the same
slot) — and call that from `execute_compute_inner` instead of `retire_all`. The
readback still waits the fence it needs; nothing else on the device is waited
for; the heartbeat keeps the graveyard moving.

### Verification

- `cargo check -p reims-vgpu --no-default-features --features
  backend-vulkan,host-window` passes.
- Driven session, before: the drain thread sat in `retire_all` for minutes per
  compute dispatch; the guest's render thread blocked in `MTLIOAccelBuffer
  dealloc`; screen black.
- Driven session, after: *pending — filled in when the boot image is tested.*
  The counters to read are the guest's own progress (Unity's log moving past
  asset loading) and the device's `draw_phase`/`engine_delta` advancing while
  compute dispatches run, with no long gaps in the log's timestamps.

## PR

**Title:** vulkan: wait only the entry's own fence on the CPU-visible compute path

Body: the Summary, Root cause, Proposed change, and Verification sections above.

## How to post

No `gh` CLI or GitHub credentials on this host. To file it:

```sh
# from a clone of reims-vgpu, on the pinned base
git checkout -b fix/compute-retire-scope 69a57dd6
git apply /home/tianyixia/nixos-config/packages/reims-vgpu/pr-compute-retire-scope.patch
git commit -am "vulkan: wait only the entry's own fence on the CPU-visible compute path"
git push -u origin HEAD
```

Then open the PR with the description above and the issue with the issue
section. The three preceding local fixes (tag `0x08`, metal2vulkan scalar-store
lowering, sampler-bind fallback) are documented beside this file and are
independent; this one is what the driven session needed to stop hanging.
