# Upstream report — two findings in nvidia-macos-driver 1.0.1

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
