# Upstream report — findings in nvidia-macos-driver 1.0.1

Both found while running the driver in a QEMU/KVM VM (macOS 15.8.1, RTX 5080
Max-Q `10de:2c59`, mobile Blackwell GB203M). Neither is VM-specific in principle —
the first is a timing collision, the second is a dead line of config.

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
