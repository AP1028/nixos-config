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

**Not** a factor, for the record — these were measured and ruled out:

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

## Finding 5 — changing resolution wedges the display permanently

Selecting any other display mode leaves a **blank background with a live cursor**.
Nothing is presented until WindowServer is restarted, which logs the user out:

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

A mode switch that cannot be backed out without a logout is worth fixing on its
own; it also means any "did the mode change help?" experiment costs the user their
session.

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
