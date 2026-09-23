# Upstream report: device scalar store into an aggregate pointee is refused

Status: **fix verified against the captured corpus; device build carries it**
(see Verification). This file is the issue text and the PR description; the
patch is `packages/reims-vgpu/metal2vulkan-scalar-aggregate-store.patch` in this
repo (also applied to the vendored dependency in the build), generated against
`9e0e99a41dc3cb8bb7e288b531f1698a79fd4b1c`.

---

## Issue

**Title:** `native emitter: owned Store violates its pointer-pointee and
value-type contract` refuses a legal device store into an aggregate

### Summary

Translating a Metal compute kernel that stores a scalar into an aggregate
pointee in the **device** address space fails outright:

```
m2v_kernel_translate detail=native_emitter:_owned_Store_violates_its_pointer-pointee_and_value-type_contract
```

The store in question is a legal opaque-pointer store — LLVM types the pointer
opaque, so the access is defined by the value's type, not by the GEP's
structural element type. Metal's own compiler emits this shape for `as_type`
reinterpretations and for hand-written packed vertex layouts.

The native emitter already knows how to lower this: `store float` through a
pointer to `[10 x i32]` is an access chain to the first element plus an
`OpBitcast` of the value. `emit_first_scalar_aggregate_reinterpret_store` does
exactly that, but it returns early unless the pointer lives in
`Function`, `Workgroup`, or `Private` storage, so a `StorageBuffer` store falls
through to the raw `OpStore` path, whose pointee (`%_ptr_StorageBuffer__struct_N`)
disagrees with the value type (`%float`), and the owned-module verifier refuses
the whole module.

### Impact

Unity's GPU skinning / blend-shape compute kernels are refused, so the game's
skinned draws never execute. In the reims-vgpu guest (Easy Red 2, Unity
2022.3.62f3) the game window presents at ~60 Hz with audio and the canvas stays
black. Two kernels per launch are refused this way, and every later dispatch
through those pipelines fails.

### Environment

- Host: NixOS 26.11, kernel 7.2.4, KVM, NVIDIA RTX 5080 Laptop, driver
  595.99.02, Vulkan backend (reims-vgpu x86_64 rail).
- Guest: macOS 13.7.8 (22H730) x86_64, `reims-vgpu-pci`.
- metal2vulkan `9e0e99a41dc3cb8bb7e288b531f1698a79fd4b1c`.
- AIR captured from the guest with the device's `REIMS_VGPU_AIR_CAPTURE=on`
  switch (`kernel-5652.air`, `kernel-6724.air`).

### Root cause

`src/native/emitter/body/vector_store.rs`,
`Emitter::emit_first_scalar_aggregate_reinterpret_store`:

```rust
let storage = match self.resolve_type(&ptr.ty)? {
    LlType::Ptr(addrspace) => self.pointer_storage_for(&ptr.value, addrspace)?,
    ...
};
if !matches!(
    storage,
    StorageClass::Function | StorageClass::Workgroup | StorageClass::Private
) {
    return Ok(false);
}
```

The load sibling (`emit_first_scalar_aggregate_reinterpret_load`) and the vector
sibling (`emit_first_vector_aggregate_reinterpret_store`) of the same lowering
have no such restriction; the access chain they build is valid in every storage
class, and `spirv-val` accepts it. The scalar-store guard is the only one of the
three, and it is what turns this legal store into a refused module.

### Reproduction

The captured kernel is 6 724 bytes of AIR (the second is 5 652). A minimal
sanitized-`.ll` reproduction, run through the crate's own harness:

```sh
cargo run -q --features serde --example translate_reflected -- repro.ll out.spv out.json kernel
```

```llvm
target triple = "spirv-unknown-vulkan1.2"
%struct.Vertices = type { [10 x i32] }

define void @main(ptr addrspace(1) %out) {
entry:
  %slot = getelementptr inbounds %struct.Vertices, ptr addrspace(1) %out, i64 0, i32 0
  %raw = bitcast ptr addrspace(1) %slot to ptr addrspace(1)
  store float 1.000000e+00, ptr addrspace(1) %raw, align 4
  ret void
}

!air.kernel = !{!0}
!0 = !{ptr @main, !1, !2}
!1 = !{}
!2 = !{!3}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.struct_type_info", !4, !"air.arg_type_size", i32 40, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"Vertices", !"air.arg_name", !"out"}
!4 = !{i32 0, i32 4, i32 10, !"uint", !"value"}
```

Before: `FALLBACK: native emitter: owned Store violates its pointer-pointee and
value-type contract`. After: translates and passes `spirv-val`, with

```
%_ptr_StorageBuffer_uint = OpTypePointer StorageBuffer %uint
         %23 = OpBitcast %uint %float_1
         %24 = OpInBoundsAccessChain %_ptr_StorageBuffer_uint %14 %uint_0 %uint_0
               OpStore %24 %23
```

### Proposed change

Drop the storage-class guard. The lowering it gates emits an access chain to the
first scalar plus a same-width `OpBitcast` of the value — byte-identical and
legal SPIR-V in any storage class — and the two sibling lowerings already run
everywhere. A regression test with the IR above is included.

### Verification

- Both captured kernels (`kernel-5652.air`, `kernel-6724.air`) translate and
  pass `spirv-val` after the change; both fail before it.
- The full corpus of shaders captured from one Easy Red 2 session (113 modules:
  kernels, fragments, vertices) translates and validates 113/113.
- `cargo test -p metal2vulkan`: 1772 passed, 1 failed —
  `owned_derivative_execution_model_check_matches_vulkan_validation`, which
  fails identically on the pristine tree here (it asserts `spirv-val` rejects a
  derivative reachable from GLCompute, and the local `spirv-val` accepts it), so
  it is an environment/version artifact, not a regression.
- The device build used for the guest verification carries this patch against
  the vendored crate.

## PR

**Title:** native: lower scalar stores into aggregate device pointers instead of refusing them

Body: the Summary, Root cause, Proposed change, and Verification sections above,
plus the regression test
(`native_device_aggregate_scalar_reinterpret_store_targets_first_field`).

## How to post

No `gh` CLI or GitHub credentials on this host. To file it:

```sh
# from a clone of metal2vulkan, on the pinned base
git checkout -b fix/device-aggregate-scalar-store 9e0e99a41dc3cb8bb7e288b531f1698a79fd4b1c
git apply /home/tianyixia/nixos-config/packages/reims-vgpu/metal2vulkan-scalar-aggregate-store.patch
git commit -am "native: lower scalar stores into aggregate device pointers instead of refusing them"
git push -u origin HEAD
```

Then open the PR with the description above, and the issue with the issue
section. The captured AIR (`kernel-5652.air`, `kernel-6724.air`) is worth
attaching; it is on this host at `/tmp/reims-vgpu-air/` while the capture
session lives, and can be re-captured with `REIMS_VGPU_AIR_CAPTURE=on`.
