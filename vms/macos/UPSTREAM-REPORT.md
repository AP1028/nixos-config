# Upstream report — findings in nvidia-macos-driver (1.0.1 → 1.0.9)

Written while running the driver in a QEMU/KVM VM (macOS 15.8.1, RTX 5080 Max-Q
`10de:2c59`, mobile Blackwell GB203M). Findings 1-11 are from driver 1.0.1; 12-15 were
found on 1.0.9 with the configuration finally working.

> **Status update — read this first.** The environment these findings came from has since
> been fixed, and the fix changes the severity of several of them. One QEMU property:
>
> ```
> -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
> ```
>
> lets macOS resource a passed-through device **behind a PCIe root port**, so
> `placeLargeBar1()` finds the parent bridge it requires and places a **16 GiB BAR**, with
> an **8 GiB VRAM budget** instead of 192 MB.
>
> Consequences:
>
> * **Finding 11 is superseded** — a ≥4 GiB BAR *does* work in a VM. Corrected in place.
> * **Findings 1, 6, 7 and 10** were symptoms of the GPU being forced onto bus 0. They
>   may no longer reproduce now the device is presented normally, and should be
>   re-checked before acting on them.
> * **Findings 12-15 are new.** **Finding 12 is the most serious** — it is the only one
>   that breaks a running session, and the only one that needs a workaround to use the
>   machine at all.
>
> Configuration: `WORKING-RECIPE.md` in this directory.

---

## Finding 1 — the 40 s boot-hold cap expires before the 100 s auto-go, so the display never arms with WindowServer up

**Severity:** high in any configuration where `placeLargeBar1()` fails. It makes
the Metal desktop unreachable, i.e. the README's *"your NVIDIA card drives the
desktop"* and *"NVAccel the accelerator WindowServer composites through"* cannot
happen.

**Expected design.** `NVRM` holds the IORegistry busy so WindowServer's
`IOKitWaitQuiet` blocks until the driver has armed the display, which is what
sequences WindowServer to start *after* NVRM is ready:

```c
// kexts/NVRM/NVRM.cpp, ~line 328
fBootHold = 1; adjustBusy(1); setProperty("nvrm-boot-hold", "holding");
if (thread_call_t cap = thread_call_allocate(&NVRM::bootHoldCap, this)) {
    uint64_t dl; clock_interval_to_deadline(40000, kMillisecondScale, &dl);
    retain(); thread_call_enter_delayed(cap, dl);
}
...
setProperty("nvrm-autogo", bar1Placed ? "scheduled +10 s" : "scheduled +100 s");
LOG("auto-go: go(2) in %u ms on its own thread (BAR1 %s); registry held busy "
    "until the display is armed (cap 40 s)",
    fAutoGoSettleMs, bar1Placed ? "placed outside the console" : "not placed");
```

The cap is a **fixed 40 s**, but the schedule it is racing is **either 10 s or
100 s**:

```c
uint32_t fAutoGoSettleMs = 10000;                     // ~line 106
// ... and 100000 when bar1Placed is false
```

| `bar1Placed` | auto-go | vs 40 s cap | outcome |
|---|---|---|---|
| true | `+10 s` | 10 < 40 | hold outlives bring-up → WindowServer waits → **Metal desktop** |
| false | `+100 s` | 100 > 40 | **cap fires first** → WindowServer proceeds → no Metal desktop |

**Observed**, with `bar1Placed == false` (macOS assigned only a 256 MB BAR1, so
`placeLargeBar1()` returned false):

```
NVRM-xnu: auto-go: go(2) in 100000 ms on its own thread (BAR1 not placed);
          registry held busy until the display is armed (cap 40 s)
NVRM-xnu: boot hold RELEASED by the 40 s cap
```

`bootHoldCap()` even predicts the consequence in its own log line:

```c
// kexts/NVRM/NVRM.cpp, ~line 494
setProperty("nvrm-boot-hold", "CAP 40 s — bring-up not finished, NOT arming");
LOG("boot hold RELEASED by the 40 s cap — the bring-up will not arm with WindowServer up");
```

So the driver knows it has lost the race, and the desktop comes up with no
accelerator. Nothing recovers it later: restarting WindowServer by hand to pick
the driver up mid-session gives WindowServer a Metal path it cannot sustain, and
the UI freezes (cursor still moves — that is NVRMFB's hardware cursor plane, not
WindowServer's).

### Workaround, since the cap is not configurable

The cap itself is hardcoded, but the *other* side of the race is not — the driver
reads an undocumented boot-arg for the settle time:

```c
fAutoGoSettleMs = bar1Placed ? 500 : 100000;
{ uint32_t ms = 0; if (PE_parse_boot_argn("nvrmsettle", &ms, sizeof(ms))) fAutoGoSettleMs = ms; }
```

`nvrmsettle=15000` moves the bring-up back inside the 40 s window and the whole
designed sequence then works:

```
auto-go: go(2) in 15000 ms on its own thread (BAR1 not placed); registry held busy until the display is armed (cap 40 s)
boot hold RELEASED (display armed)          <- not "by the 40 s cap"
MTLCopyAllDevices -> 1                      <- Metal 3, self-armed by the driver
```

with no sysctls, no daemon and no WindowServer restart. So finding 1 is
**workable-around but still a bug**: the default is wrong for every system where
`placeLargeBar1()` cannot succeed, and `nvrmsettle` is undocumented. Worth either
deriving the cap from `fAutoGoSettleMs` (the suggested fix) or documenting the
boot-arg in the README.

**Suggested fix — derive the cap from the schedule**, e.g.

```c
clock_interval_to_deadline(fAutoGoSettleMs + 40000, kMillisecondScale, &dl);
```

so the hold always outlives the bring-up whichever path is taken. Trade-off worth
deciding deliberately: on the slow path this blocks WindowServer for ~100 s, which
is a visibly slower boot. An alternative is to make the slow path faster (arm the
display before BAR1 is resolved), but that is a larger change.

**How to reproduce without special hardware:** anything that makes
`placeLargeBar1()` return false, i.e. any system where macOS assigns only the
default non-Resizable-BAR aperture. In our case the host BAR1 is 256 MB:
macOS's `IOPCIFamily` lists BAR1 in the device's `reg` but never in
`assigned-addresses`, so no `IODeviceMemory` descriptor exists, and the driver
falls back to PCI BAR3 as its VRAM aperture. Note that this same fallback is what
makes the driver fail outright at larger BAR sizes
(`kbusVerifyBar2_GB202: MMUTest ... returned garbage 0x0`,
`NV_ERR_MEMORY_ERROR @ kern_bus_gm107.c:362`), so on such a system the 256 MB BAR1
is the only way to get the driver running at all — and it is exactly the case the
40 s cap does not accommodate.

---

## Finding 2 — `nvmtl-allow.txt` ships with its WindowServer rule unreachable

**Severity:** low on its own (the practical effect is the same as writing `*`),
but it makes the armed-only gate on WindowServer a no-op and is easy to fix.

`nvmtl_allowed()` in `plugin/NVMTLDevice.m` stops at the **first matching line**:

```c
if (*p == '-') { ...deny, return false... }              // '-' = hard deny
if (*p == '!') { armedOnly = true; ... }                 // '!' = allow only when armed
if (strcmp(p, "*") && strcmp(p, me)) continue;
if (armedOnly && !nvmtl_accel_armed()) { ... break; }
ok = true; break;                                        // FIRST match wins
```

The shipped file is:

```
# rung 3: everyone; -Name denies
*
!WindowServer
```

The `*` line matches first, so `ok = true; break` — **`!WindowServer` is never
reached** and the "armed-only" restriction on WindowServer never applies.
WindowServer is granted the Metal plugin as soon as `MetalPluginName` is
published.

**Fix — put the specific rule first:**

```
-WindowServer
*
```

**Verified** without rebuilding, since the check is by `getprogname()`: copying a
Metal test binary to a file named `WindowServer` and running it prints
`no Metal device`, while the same binary under any other name gets the device.

Note also that `lsof -p <WindowServer> | grep NVMTLDriver` is **not** a valid
signal here — the Metal framework `dlopen`s the plugin bundle to ask it for
devices even when the allow-list refuses, so the library shows as mapped either
way.

**Related:** arming `debug.nvaccelfb=1` additionally sets
`IOGLBundleName=AppleMetalOpenGLRenderer` on the accelerator
(`kexts/NVRM/accel/nvrm-accel.cpp`), which redirects the GL renderer
**globally** — so excluding WindowServer from the Metal *plugin* does not
necessarily keep it off a GL-over-Metal path. Also, arming cannot be undone at
runtime: `sysctl -w debug.nvaccelfb=0` has no effect (the driver documents this —
*"a reboot takes it away again"*), so any mis-step costs a reboot. If that is
intended, fine; it is worth stating in the README, because it makes the gate
expensive to experiment with.

---

## Finding 3 — WindowServer saturates a core to composite

**Severity:** usability. The desktop works but is not responsive; the compositor
is CPU-bound.

With the desktop GPU-composited and Metal 3 available, WindowServer holds **~98%
of one CPU core continuously** (cputime 11:28.00 -> 11:37.76 over 10 s wall). A
compositor should be near-idle when the GPU is doing the work. Sampling it shows
where the time actually goes:

```
33  mach_msg2_trap
21  io_connect_method                      (IOKit)
16  IOConnectCallMethod                    <- user -> kernel round-trips
12  nvrm_xnu_ioctl     (libvulkan_nouveau) <- the kernel driver entry point
 9  CA::OGL::render_layers  (QuartzCore)   <- CoreAnimation, over OpenGL
 7  nvRmApiFree       (libvulkan_nouveau)
 5  nvkmd_nvrm_va_free (libvulkan_nouveau)
```

So the cost is **ioctl round-trips plus RM object / VA teardown**, not GPU work
and not memory transfers. Two candidate explanations worth the author's attention:

1. **Per-operation syscall overhead.** `nvrm_xnu_ioctl` sitting that high means
   the user↔kernel channel is on the hot path for every compositing operation.
2. **Object churn.** `nvRmApiFree` and `nvkmd_nvrm_va_free` appearing in the top
   ten suggests RM objects and VA ranges are being created and destroyed per frame
   rather than pooled.

Contributing factor: the display is driven at **165 Hz** at 3440x1440
(`IOFBCurrentPixelClock = 879720000`), so this chain runs 165 times a second.

**Update after further work:** the magnitude was largely self-inflicted by the
shipped `nvrm610.conf` — see Finding 6, which recovers 3-4x. What remains after
that is bounded by the 192 MB surface budget the 256 MB BAR imposes. The
measurements below still stand as refutations of the *bandwidth* theory:

| measurement | value |
|---|---|
| GPU fill / copy | 467 GB/s (exceeds PCIe, so buffers really are in VRAM) |
| GPU fma | ~5.3 TFLOPs fp32 (card does ~30-50 native) |
| `nvAllocVram` BAR1 refusals | zero |
| BAR1 grant budget | 192 MB, 174 MB mapped, **stable** (no thrash over 10 s) |
| static vs dynamic wallpaper | 9.74 s vs 9.76 s per 10 s — no difference |

## Finding 4 — no lower refresh rate is published at the native resolution

`NVRMNVDAFramebuffer` publishes 26 modes, but only one at the native timing:

```
  3440x1440 @ 165.0 Hz       <- the only native-resolution mode
  1920x804  @ 165.0 Hz   ·  2048x858 @ 165.0 Hz  ·  1720x720 @ 165.0 Hz
  1280x720  @  60.0 Hz   ·  1280x960 @ 60.0 Hz   ·  1024x768 @ 60.0 Hz ...
```

The 165 Hz variants are clearly derived from the native timing, and the 60-75 Hz
entries are VESA defaults. There is no way to select, say, 3440x1440 @ 60 Hz, even
though the panel's EDID range descriptor permits a much wider range.

This matters because 165 Hz is the single largest multiplier on the Finding 3 cost
— a user who wants a responsive desktop currently has to drop resolution as well
as refresh. Publishing at least one lower refresh at the native timing would make
that trade-off avoidable.

## Finding 5 — changing resolution wedges the display, and is the context of a KERNEL PANIC

**Two severities here.** Selecting any other display mode leaves a **blank
background with a live cursor**. Nothing is presented until WindowServer is
restarted, which logs the user out:

```sh
sudo launchctl kickstart -k system/com.apple.WindowServer
```

Diagnostics gathered while wedged:

* **WindowServer does not crash.** Same pid, no crash report, session still logged
  in (`console user` unchanged).
* **It goes idle, not spinning.** cputime advanced **0.01 s over 6 s** — it has
  stopped compositing entirely.
* `IOFramebuffer` count rises (8 -> 10), so new framebuffers were created for the
  new mode.
* The **mode itself is not damaged**: querying the display afterwards reports
  `3440x1440 @ 165`, i.e. it is already back at the original timing. So the damage
  is to the presentation path, not the mode.

### And the same code path panics

Separately, a **kernel panic** occurred with a display mode change in flight. The
serial console shows the sequence immediately before it:

```
NVAccel: DM displayModeWillChange
NVAccel: DM displayModeWillChange
NVRM-xnu: MSI #35000 -> work loop (handled so far 31823)
NVRM-fb: setAttribute 'spwr' value 3758097168 -> 0xe00002c7
Debugger called: <panic>
Nested panic detected - entry count: 2 panic_caller: 0xffffff80109d360e
Nested panic string:
Ticket lock 0xffffff8010f3d480 is unexpectedly owned by thread 0xffffff9037973b30 @lock_ticket.c:143
```

The resulting report contains **no stackshot at all**:

```json
{"macOSProcessedStackshotData":"bm8gb24gZGlzayBvciBzbGVlcC93YWtlIGZhaWx1cmUgcGFuaWNrc3Rhc2hvdCBmb3VuZA==",
 "macOSPanicString":"Nested panic detected - entry count: 2 panic_caller: 0xffffff80109d360e"}
```

which decodes to *"no on disk or sleep/wake failure panic stackshot found"* — the
panic handler panicked before capturing anything, so there is no backtrace to work
from. Two `Kernel-*.panic` reports exist on this machine.

The lock is a `lock_ticket` ticket lock held by another thread, i.e. a lost
unlock or a lock taken on a path that then panicked — consistent with a
re-entrancy problem around the accelerator's display-pipe transaction path, which
is what a mode change drives (`performTransaction`) and which also does the
`spwr` power-attribute write seen just before.

**This makes mode changes a crash-risk operation on this driver, not merely an
inconvenience.** If the author wants a reproducer, changing resolution in System
Settings on a 256 MB-BAR system should reach it.

A mode switch that cannot be backed out without a logout is worth fixing on its
own; it also means any "did the mode change help?" experiment costs the user their
session — and may cost them the machine.

---

## Finding 6 — the shipped `nvrm610.conf` throttles the compositor by 3-4x

**Severity:** high and trivially fixable. This is the difference between a desktop
that is unusable and one that is fine.

`/Library/GPUBundles/nvmtl/nvrm610.conf` ships in the tarball with values far more
conservative than the driver's own code defaults:

| knob | shipped | code default |
|---|---|---|
| `NVMTL_VRAM_WS_NONIMAGE_MB` | `0` | `NVMTL_VRAM_NONIMAGE` = `2655` (`plugin/nvmtl_vk.c:121`) |
| `NVMTL_VRAM_HEADROOM_MB` | `256` | `NVMTL_VRAM_HEADROOM_DEFAULT` = `1024` (`plugin/nvmtl_vk.c:122`) |
| `NVMTL_RES2_WS` | `0` | enabled (`plugin/nvmtl_vk.c:1501`) |

`NVMTL_RES2_WS=0` is the significant one. In `nvmtl_vk_working_set()`:

```c
static int res2 = -1; ... const char *w = getenv("NVMTL_RES2_WS");
    res2 = !(w && w[0] == '0') && g_sparse && ...;
if (res2 && nvmtl_vk_vram_bytes()) return nvmtl_vk_vram_bytes();   // whole card
```

Setting it to `0` disables the branch that returns the card's full VRAM, leaving a
budget-derived working set instead. `NVMTL_VRAM_WS_NONIMAGE_MB=0` additionally
gives non-image allocations no VRAM at all.

**Measured effect** (RTX 5080 Max-Q, 3440x1440 @165, macOS 15.8.1):

| | shipped conf | code defaults |
|---|---|---|
| dragging a window | **16-21 fps** | **58-80 fps** |
| idle | ~137 fps continuously | **0 fps** (correctly idle) |
| VRAM mapped | 175/192 MB | 175/192 MB (**unchanged**) |
| refusals | none | none |

Worth noting the mapped figure does **not** change — the gain is not from using
more memory but from the plugin no longer thrashing its allocation decisions
against a working set it believes is tiny. That suggests the shipped values were
chosen for a much smaller/older configuration and are counter-productive on a
16 GB card.

**Suggested fix:** ship the code defaults, or at least drop the explicit
`NVMTL_RES2_WS=0` / `NVMTL_VRAM_WS_NONIMAGE_MB=0` overrides so the compiled
defaults apply. Documenting that a WindowServer restart is needed to pick up conf
changes would also help — the knobs are read once at plugin load
(`plugin/NVMTLObjects.m:100`), so editing the file appears to do nothing until the
next logout.

**Residual, after this fix:** the surface budget is still 192 MB and sits ~93% full
(179 MB), so a GPU-composited heavyweight like Steam regresses the compositor and
closing it recovers. That is Finding 7's territory — the small-BAR ceiling — not
something the conf can address.

## Finding 7 — a 256 MB BAR leaves the compositor ~13 MB of headroom

When macOS will not assign a Resizable BAR above 256 MB (see the host-side notes),
`NVRM_VRAM_BAR1_BUDGET` caps the framebuffer's VRAM grants at **192 MB**
(`kexts/NVRM/nvrm_vram_abi.h:15`), and the budget is normally ~93% occupied:

```
debug.nvrmfb_vram_mapped_bytes: 179 MB of 192 MB
debug.nvrmfb_vram_grants: 76 / 66 releases
```

With ~13 MB free, any additional GPU-composited client crowds the compositor out —
observed with Steam, which regresses window dragging from ~60-80 fps back toward
the teens, and closing it recovers immediately. No `nvAllocVram: REFUSED` messages
appear, so this is crowding rather than clean exhaustion.

Because the budget only grows when `fBarLen >= 4 GiB` (`fBarLen / 2`), there is no
way to raise it on a system where macOS assigns only the default aperture. Two
suggestions:

1. `vramGrant` could **reclaim** parked/released grants more aggressively when
   `before + want > budget` rather than refusing, since the counters show 76 grants
   against 66 releases — there is churn to reclaim.
2. A small-BAR system would benefit from the framebuffer reserving less for itself,
   or from surfacing the budget pressure to the client (e.g. an `IOSurface`
   allocation failure rather than a silent slowdown).

## Finding 8 — `NVMTL_HWPOOL=1` installs private pool classes and correlates with a panic

`plugin/NVMTLDevice.m:319` reaches for Apple's private pool machinery:

```c
Class POOL = objc_getClass("MTLIOAccelResourcePool");
Class RES  = objc_getClass("MTLIOAccelPooledResource");
...
pools[i] = mk([POOL alloc], init, dev, RES, args[i], 2440, 0);
set(dev, NSSelectorFromString(@"setHwResourcePool:count:"), pools, 3);
```

with a hand-built 2440-byte `resourceArgs` blob. Setting `NVMTL_HWPOOL=1` in the
conf correlated with the kernel panic in Finding 5 on the boot where it was
enabled, and a benchmark run under it produced **10 fps** (which may itself have
been the crash rather than a slowdown). There is no backtrace to prove causation,
so this is reported as a correlation, not a diagnosis — but it is private-API
plumbing behind an undocumented flag with **no measured benefit**, and it is
reverted in our configuration. Flagging it in the README as experimental would be
enough to stop others losing a machine to it.



## Finding 9 — `gParkedForever` leaks the VRAM budget permanently, until nothing can allocate

**Severity: high on any small-BAR system.** This is the difference between a
desktop that works for an hour and one that stops allocating altogether.

`nvAllocVram` retries an allocation that lands on the console/scanout range by
*parking* it and rolling again. Parked entries are never freed:

```c
static struct { struct NvKmsKapiMemory *m; void *k; NvU64 n; } gParkedForever[24];
static volatile SInt64 gVramParkedBytes = 0;
...
gParkedForever[gNParkedForever++] = {m, k, want};
OSAddAtomic64((SInt64)want, &gVramParkedBytes);
```

Every reference to `gParkedForever` / `gVramParkedBytes` in the tree is the
declaration, the store, or the budget arithmetic — **there is no free path, no
reset, and no sysctl.** The budget check counts them as if they were live:

```c
SInt64 before = OSAddAtomic64((SInt64)want, &gVramMappedBytes) + gVramParkedBytes;
if (before + (SInt64)want > budget) { FBLOG("...REFUSED — BAR1 budget spent..."); return false; }
```

**Observed consequence.** On a 256 MB BAR the budget is `NVRM_VRAM_BAR1_BUDGET` =
192 MB. After a few hours of uptime:

```
mapped 185 MB / budget 192 MB
nvAllocVram(8323072): REFUSED          <- every attempt
vramtest: holding 0 x 8 MB             <- 8 MB, 16, 32, 48, 64, 96, 128 MB: all refused

this boot: parks 5136   park-ceiling hits 5137   REFUSED 771   grants 12
```

**Twelve** grants in a whole boot. The growth from ~155 MB (just after boot) to
185 MB matches the 24 MB `NVRM_VRAM_PARK_CEILING`, and
`185 live + ~24 parked > 192` is precisely the state that refuses everything. The
user-visible effect is that the first interaction with any new window sticks for
about a second — an allocation failure being retried — and it gets worse with
uptime and with additional GPU clients (Steam).

**Suggested fix.** Parked entries are *rejects*: the retry that parked them may
well succeed once other grants are released, so they are the best possible
reclaim candidate. Freeing them (or simply not counting them against the budget)
when `before + want > budget` would let the driver recover instead of degrading to
zero allocatable VRAM. A sysctl to drop them would be enough for users to recover
without a reboot — currently a reboot is the only reset.

**Also worth considering:** parking only ever happens because those allocations
land on the console/scanout range. Reserving that range in the allocator rather
than detecting collisions after the fact would avoid the leak entirely.

## Finding 10 — the driver's BAR table depends on IODeviceMemory descriptors, so a >4G BAR silently disables it

**Severity: medium (breaks loudly, but by a non-obvious route).** On a system that
hands the GPU a large Resizable BAR, the driver maps nothing and fails outright.

macOS assigns large BARs correctly — 2 GiB and 4 GiB both landed at
`0x1000000000` per QEMU's view of the config space — and the ReBAR capability reads
back fine (`bar1: Resizable BAR capability @0x134 says BAR1 = 4096 MB`). What
macOS does **not** do is publish an `IODeviceMemory` descriptor for a BAR placed
**above 4G**. Below 4G it does; above 4G it does not. The rule is the address, not
the size.

Both `readBARs()` and `nvrmDiscoverBar1()` derive everything from those
descriptors:

```c
unsigned count = fPCI->getDeviceMemoryCount();
... IODeviceMemory *dm = fPCI->getDeviceMemoryWithIndex(idx); ...
        nv->bars[curNvBar].cpu_address = phys;
        nv->bars[curNvBar].size        = size;
```

```c
static void nvrmDiscoverBar1(IOService *provider, NvU64 *length, NvU64 *base) {
    ... if (!memory || memory->getLength() < 0x10000000ull) continue;
        *length = memory->getLength(); ...
```

so with no descriptor:

* `bars[NV_GPU_BAR_INDEX_FB]` silently becomes **BAR3** (32 MB, non-VRAM)
* `rm_init_adapter` fails on `kbusVerifyBar2` and `auto-go` reports `go(2) failed`
* `fBarLen` is 0, so the grant budget is 0 and Metal exposes **no devices at all**
* `placeLargeBar1()` does not rescue it — it requires a bridge parent and logs
  `bar1: parent root port not found` when the GPU is on the root bus (which it must
  be, per Finding 2's sibling issue: macOS will not enumerate a device behind a
  PCIe root port)

Net: **a bigger BAR is strictly worse than a small one on this driver**, because a
small BAR is at least described.

**Suggested hardening, since a driver cannot rely on descriptor publication:** read
the BAR *size* from the Resizable BAR capability (which works at every size, as the
log shows) and fall back to probing the BAR registers when no descriptor matches —
`IOPCIDevice::configRead32(0x10 + 4*bar)` gives the address macOS programmed even
when no `IODeviceMemory` exists. That would make a >4G BAR work rather than fail.

**For users, meanwhile:** ~~256 MB is the only value that works~~ — **superseded.** With
the root-port fix (see the status note at the top) a 16 GiB BAR works and the driver
places it itself. This finding was a symptom of the GPU being forced onto bus 0, where
`placeLargeBar1()` had no parent bridge; the descriptor dependency it describes may still
be real, but it no longer blocks a large BAR.

## Finding 11 — a >= 4 GiB BAR is unusable in a VM, though it works on bare metal

> **SUPERSEDED — a large BAR works in a VM.** The blocker was never the BAR size: it was
> that macOS would not resource the device behind a root port, so the GPU sat on bus 0 and
> `placeLargeBar1()` failed with `bar1: parent root port not found`. Fix that (one QEMU
> property) and a 16 GiB BAR is placed successfully, budget 8 GiB. The measurements below
> are still accurate *for a GPU on bus 0* and are kept as a record of the failure mode.
> The 8 GiB "QEMU dies with a non-canonical address" case also no longer occurs, because
> macOS now programs a sane address instead of garbage — it never generates one when the
> device is resourced normally.

**Context for the author:** `app/Resources/nullmoth-setup.sh` configures an
installed system with `ResizeGpuBars = 13` (8 GB) and `ResizeAppleGpuBars = -1`,
i.e. a full BAR and macOS seeing all of it. That is exactly right on hardware. In
a QEMU/KVM VM with the card passed through, the same setup cannot be reached, and
the driver fails closed in a confusing way:

* **>= 8 GiB**: QEMU dies before the guest runs, with a non-canonical address
  (`0x8408400000000000` = a 32-bit MMIO value in the high dword). Not OpenCore's
  doing — reproduced with `ResizeGpuBars = -1`.
* **4 GiB**: QEMU boots, macOS assigns the BAR above 4G, and **no IODeviceMemory
  descriptor is published**, so `bars[FB]` becomes BAR3 and `go(2) failed`. This is
  Finding 10's descriptor dependency, and it is why a VM cannot use a large BAR.

**Suggestion:** the driver already reads the size correctly from the Resizable BAR
capability at every size (`bar1: Resizable BAR capability @0x134 says BAR1 = 4096
MB`). Falling back to the BAR registers (`configRead32(0x10 + 4*bar)`) when no
descriptor matches would make a >4G BAR work instead of failing, and would let VM
users reach the same configuration the installer sets on bare metal.

Also worth a line in the docs: host-set BAR sizes above 4 GiB are only viable if
the address assignment works, so a VM user should be told to keep a small BAR.

## Finding 12 — the scanout binding survives a display-mode transition (breaks the session)

**Severity: highest in this report.** It is the only defect that makes the machine
unusable, and the only one needing a workaround to use at all.

After a fullscreen app runs — or any display-mode transition — the panel alternates
between live content and a dead client's last frame. Progression observed in one session:

| event | result |
|---|---|
| game in exclusive fullscreen | steady flash: splash ↔ game frame |
| switched to borderless, vsync Single | bursty flash: game frame ↔ desktop |
| left alone | partner degraded to a dark screen |
| **WindowServer restart** | **stable — flash gone** |
| game switched borderless → fullscreen | **wedged again** |

### What it is not (each falsified by measurement, not argument)

* **Not the flip path.** `nvaccel_iop_flips 16766`, `iop_ok 16863`, `iop_fail 0`,
  `iop_flip_stale 0`, `iop_flip_refused 0` — every flip succeeds, by the driver's own
  accounting. `flip_stale = 0` because the driver sincerely believes the surface it scans
  out is current; the staleness is invisible to its counters.
* **Not the composite.** `screencapture` (which reads the WindowServer's composite)
  returns a stable, correct desktop across eight rapid captures, byte-identical in pairs,
  while the panel alternates.
  *(Corollary worth stating: games present through the driver's zero-copy direct scanout,
  so they never appear in that composite at all.)*
* **Not async flip recycling.** `debug.nvaccel_iop_async=0` changes nothing.
* **Not a late-published framebuffer.** Writing `debug.nvaccelfb=3` does not take (the
  value stays 1) and only one framebuffer is registered (`agdc_maxfb 1`).

### The mechanism, and the author's own comment

`kexts/NVRM/accel/nvrm-accel.cpp` documents the required remedy:

> *"it gets a pipe only when `debug.nvaccelfb=3` is written again, **and WindowServer
> composites it only after a WindowServer restart**"*

So: the composite source changes underneath a running WindowServer, which keeps
presenting to a surface bound before the change. Only a fresh WindowServer re-binds it.

### Recovery, and what does not work

* **`sudo killall -9 WindowServer`, then log in** — re-binds the scanout. ~30 s.
  **Verified.** Keeps the VM, the BAR and the config.
* **Host-side FLR** (unbind vfio-pci, `echo 1 > .../reset`, rebind) — **verified.**
* **Guest reboot does not help** — with vfio the guest driver programs the physical GPU
  and a guest reboot never resets it.
* **No effect** (all tested): Metal shader cache clear, `killall Dock`, wallpaper change,
  display sleep/wake, `debug.nvaccelfb=3`, `debug.nvaccel_iop_async=0`, and
  `nvrmctl` (only `go`/`good`/`state` — no surface or display reset).

**Request:** a way to re-bind the scanout without restarting the WindowServer — an
`nvrmctl` subcommand, or a sysctl that forces a re-bind — would turn a session-breaking
bug into a recoverable one.

## Finding 13 — the park leak eventually consumes the entire budget (quantified)

Finding 9 identified `gParkedForever` as a permanent leak. With a working 8 GiB budget the
consequences are now measurable, and the leak is what causes a specific, reproducible
symptom: **continuous window dragging is smooth, but the first drag after switching
windows stalls.**

`kexts/NVRM/fb/nvrm-fb.cpp:1261`:

```c
SInt64 before = OSAddAtomic64(want, &gVramMappedBytes) + gVramParkedBytes;
if (before + want > budget) { ...refuse... }
```

Measured by activating apps (a real window switch) and reading the counters:

```
after Finder : res_new=95   res_free=66   refused=163
after Safari : res_new=102  res_free=73   refused=177     +14
after Finder : res_new=105  res_free=76   refused=185     +8
after Safari : res_new=112  res_free=83   refused=198     +13
after Finder : res_new=119  res_free=89   refused=214     +16
after Safari : res_new=125  res_free=96   refused=230     +16
```

**8-16 refusals per window switch, climbing** — while `mapped` is 120 MB of an 8 GiB
budget. For the test to fail, `gVramParkedBytes` must be ~7.9 GiB: the parked
allocations have consumed essentially the whole budget. They are never released, so the
condition is monotonic within a boot, and running a game accelerates it because games
cycle many surfaces.

**Two requests:**

1. **Expose `gVramParkedBytes` as a sysctl.** There is no way to read it today; the
   figure above is *inferred* from the refusal condition. Diagnosing this needs the
   counter.
2. **Release parked allocations** when the console/scanout surface they overlap is gone,
   or stop charging them against every later grant.

**Note for anyone benchmarking this driver:** continuous-drag fps does not expose this.
The same session reported its best-ever figures (139.9 fps, 3.58 ms/flip, parks 0,
refusals 0) while window switching was failing. **Refusals-per-window-switch is the
metric that shows it.**

## Finding 14 — Metal → SPIR-V translation dominates runtime

`libnvmtl_translate.dylib` is the bottleneck, not the GPU. Sampling a running game:

```
2338  nvmtl_translate        ← essentially all of it
  85  Render
   2  air-
```

Entering a game world stalls for several seconds while pipelines compile, then recovers —
so it is throughput, not correctness. The same dominance appears in the WindowServer
during startup (`nvmtl_vk_pipeline_create_rt`, 1508 of 1558 samples in one sample).

**Request:** a persistent on-disk pipeline cache. The stall is the visible symptom, but
the steady-state cost is what keeps frame rates low.

## Finding 15 — `NVRM.kext` cannot be built from public sources

Reported because it blocks third-party fixes for Findings 12-14. Three independent gaps,
each verified:

1. **No build script compiles the kexts.** `build/` emits only NVAccel, NVRMAGDC, the
   plugin, the translator and NVK. `kexts/NVRM/rmcc.py:6` references `build-nvrm.sh`,
   which is not in the tree.
2. **The public `open-gpu-kernel-modules` 610.57.04 has no Darwin support.** `grep -ri
   darwin` returns zero hits; `nvport/debug.h` reaches `#error "Unsupported target OS"`;
   and `make TARGET_OS=Darwin` exits 0 while writing an **ELF** object (magic
   `7f 45 4c 46`).
3. **Unpublished artifacts are required** — `build-nvrm.sh`, `libnvkernel.a`, and
   `$NV/_out/Darwin_x86_64/compile_cmds.sh`. `accel_build.sh` exits 1 against a clean
   clone; `grep -r compile_cmds` in the public tree returns nothing.

**Additionally:** `destroyScanoutResource` and `setupScanout` are declared in
`kexts/NVRM/accel/iofam/IOAccelLegacyDisplayMachine.h` but **are headers only** — the
implementation is not in the public tree. So the display bugs in Finding 12 cannot be
patched from outside even in principle.

**Request:** publish `build-nvrm.sh`, or the Darwin port of the kernel modules, or
`libnvkernel.a`. Any of the three would let this be worked on.

## Appendix for the author — the full runtime lever inventory

Collected while working on this, in case it saves time. Everything below is
already in the source; it is listed here as a map of what can be tuned without a
rebuild.

**Boot-args read by the kexts**

```
nvfb  nvfbheads  nvaccel  nvcursor  nvfbsample  nvhud  nvhwvbl  nvrmsettle
-nvfbsurvey  -nvkmsnosmooth  -nvoff  -nvrmnobootscreen  -nvrmnoflip  -nvrmnogo
```

**Driver sysctls** (`debug.` prefix)

```
nvaccel_iop  nvaccel_iop_async  nvaccel_iop_flip  nvaccelfb  nvaccel_crc[_head]
nvrmfb_flip_interval  nvrmfb_flip_latch  nvrmfb_flip_lean
nvrmfb_flip_n  nvrmfb_flip_us_sum  nvrmfb_flip_us_max
nvrmfb_flip_latch_waits  nvrmfb_flip_latch_timeouts  nvrmfb_flip_latch_max_us
nvrmfb_agdc  nvrmfb_agdc_cmds  nvrmfb_agdc_refused  nvrmfb_agdc_fbmap  nvrmfb_agdc_maxfb
nvrmfb_vram_grants  nvrmfb_vram_grant_bytes  nvrmfb_vram_releases
nvrmfb_vram_release_bytes  nvrmfb_vram_mapped_bytes  nvrmfb_vram_budget_bytes
nvrmfb_vramtest  nvrmfb_vramtest_mode
nvrm_kms_timer_depth  nvrm_kms_timer_executed  nvrm_kms_timer_max_depth
nvrm_pageoff_coalesced  nvrm_pageoff_pages  nvrm_pageoff_perpage  nvrm_pageoff_runs
nvrm_physmap  nvrm_pvchain  nvrm_pvsentinel  nvrm_watchpage  nvrm_winraw  nvrm_winwhy
```

**Plugin env knobs** (`/Library/GPUBundles/nvmtl/nvrm610.conf`; read once at plugin
load, so a WindowServer restart is needed to pick up a change)

```
VRAM / placement : NVMTL_VRAM_WS_NONIMAGE_MB  NVMTL_VRAM_HEADROOM_MB  NVMTL_WS_FILL_PCT
                   NVMTL_RES2_WS  NVMTL_RES2_HOT  NVMTL_RES2_COLD  NVMTL_RES2_MARGIN_MB
                   NVMTL_NO_RES2  NVMTL_NO_RES2_EVICT  NVMTL_SHARED_VRAM
                   NVMTL_SHARED_VRAM_BUDGET_MB  NVMTL_SHARED_POOL_VRAM
pools / reuse    : NVMTL_HWPOOL (!)  NVMTL_POOL_REUSE  NVMTL_NO_POOL_REUSE
                   NVMTL_NO_BUFREUSE  NVMTL_NO_HEAPTEX_RECYCLE  NVMTL_NO_HEAPTEX_PLACE
                   NVMTL_TSPOOL_KEEP  NVMTL_NO_HEAP_ALIAS  NVMTL_NO_SURFACE_PAGEOFF
caches           : NVMTL_AIRCACHE  NVMTL_SPVCACHE_OFF  NVMTL_SPVCACHE_MAX_MB
                   NVMTL_SPVCACHE_TARGET_PCT  NVMTL_LINKCACHE_OFF  NVMTL_IDXCACHE_OFF
                   NVMTL_FCCACHE_OFF  NVMTL_REFLECT  NVMTL_REFLCCACHE  NVMTL_NO_LAZYAIR
submission       : NVMTL_ASYNC_COMMIT  NVMTL_DESC_BATCH  NVMTL_PRESUBMIT_PROLOGUE
                   NVMTL_NO_DIRTYONLY  NVMTL_NO_NOCOPY  NVMTL_NO_PURGE_RECLAIM
fills / clears   : NVMTL_ZERO_FILL  NVMTL_MANAGED_EAGER_ZERO  NVMTL_DONTCARE_CLEARS
```

Defaults worth knowing (verified in the source, not assumed): **dirty-only bindings
are ON** (`on = !(e && *e && *e != '0')`), **pool reuse is ON**, **buffer reuse is
ON**, and **`NVMTL_HWPOOL` is OFF** — see Finding 8.

## Environment

| | |
|---|---|
| Driver | nvidia-macos-driver 1.0.1 (1401) |
| Guest | macOS 15.8.1 (24H32) |
| GPU | NVIDIA RTX 5080 Max-Q, `10de:2c59`, mobile Blackwell GB203M |
| Host | QEMU 11.1.1 / libvirt, `pc-q35-10.2`, NixOS |
| BAR1 | 256 MB (host-side; macOS will not assign a larger Resizable BAR) |
| boot-args | `nvfb=1 nvaccelfb=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 debug=0x8 serial=1` |

What works here: the driver loads all four kexts, `rm_init_adapter -> OK`,
`PASS 2 REACHED`, four `NVRMDisplay` nubs published, `VRAM,totalsize` published,
NVRMFB drives the connected monitor at 3440x1440 @ 165 Hz with a correct EDID,
and `IOFramebuffer` goes 0 → 5. The only missing piece is Metal — which, per
Finding 1, is a sequencing consequence of the small BAR rather than anything
wrong with the accelerator itself.
