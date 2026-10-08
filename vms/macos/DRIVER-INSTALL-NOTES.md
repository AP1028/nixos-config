# NullMoth NVIDIA driver in a QEMU/KVM macOS VM

A working configuration for passing an NVIDIA GPU through to a macOS 15 guest and
running the [NullMoth nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)
on it. Written from a machine where it now works end to end.

**Status:** working. The driver comes up, the GPU drives its own output, and Metal 3
is available to applications.

**Tested environment**

| | |
|---|---|
| Host | ASUS ROG laptop, Intel Core Ultra 9 285H, NixOS, QEMU 11.1.1 / libvirt |
| Host display GPU | Intel Arc iGPU (stays on the host) |
| Passed-through GPU | NVIDIA RTX 5080 Max-Q, `10de:2c59`, mobile Blackwell GB203M |
| Guest | macOS 15.8.1 (24H32), OpenCore, NullMoth driver 1.0.1 |
| Machine type | `pc-q35-10.2`, 12 vCPU, 32 GiB |
| Monitor | Sceptre O34, 3440x1440 @ 165 Hz, on the GPU's DP-1 |

The driver's own README was written for **bare metal + OpenCore**. This document
covers the parts that differ in a VM. Read their README first.

---

## TL;DR — six things must be right

If you get these six right, the driver works end to end: GPU-composited desktop
**and** Metal 3 for applications, at usable speed. Each has a distinctive failure
signature, so you can tell which one you've got wrong.

| # | Requirement | If wrong |
|---|---|---|
| 1 | **BAR1 must be 256 MB** (set on the *host*) | driver loads but `rm_init_adapter` fails; no display |
| 2 | **GPU on guest bus `0x00`** — not behind a PCIe root port | macOS never sees the card at all |
| 3 | **`<video>` = `none`** | the emulated GPU competes with NVRMFB for display index 0 |
| 4 | **USB hostdevs on an XHCI controller** | passed-through keyboard/mouse never appear in macOS |
| 5 | **`nvrmsettle=15000` in boot-args** | driver runs but **no Metal and no GPU compositing** — see below |
| 6 | **`nvrm610.conf` at the code defaults** | desktop works but dragging windows runs at **16-21 fps** instead of 58-80 |

Requirement 5 is the non-obvious one and the subject of the next section. With it
in place **no runtime steps are needed at all**: no sysctls, no daemon, no
WindowServer restart. The driver arms the display and the Metal plugin itself
during boot. (An earlier revision of this document prescribed three runtime gates
and a boot daemon; both turned out to be workarounds for a race that `nvrmsettle`
removes.)

---

## 1. BAR1 must be 256 MB

This is the single most important finding, and the least obvious.

macOS's `IOPCIFamily` will not publish an `IODeviceMemory` **descriptor** for a
Resizable BAR placed **above 4G**, and the driver's BAR table is built from those
descriptors. (An earlier revision said macOS "will not assign" a large BAR — that
was wrong, see *Why a large BAR cannot work here* below: it assigns them fine.)
At 1 GiB or 4 GiB it lists BAR1 in the device's `reg` property (so it knows the BAR
exists) but never in `assigned-addresses`, so **no descriptor is created**:

```
reg            : ... 14200004 20000000 ...     <- BAR1 is present
assigned-addrs : BAR0, BAR3, BAR5, ROM         <- BAR1 is absent
```

The NullMoth driver's `readBARs()` fills `bars[]` from the *assigned* apertures,
so `bars[NV_GPU_BAR_INDEX_FB]` silently became **PCI BAR3 (32 MB)** — a non-VRAM
window. The driver hands that to NVIDIA's RM as `fb_address`/`fb_size`, and the
RM asserts (captured over a serial console):

```
NVRM: GPU0 kbusVerifyBar2_GB202: MMUTest BAR0 window offset 0x70e000 returned garbage 0x0
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Generic memory error
      [NV_ERR_MEMORY_ERROR] (0x00000072) returned from kbusVerifyBar2_HAL(...)
      @ kern_bus_gm107.c:362
NVRM-xnu: rm_init_adapter -> FAILED
NVRM-xnu: auto-go: go(2) -> 0xe00002bc (fPassDone 1)
```

→ no `NVRMDisplay` → no `IOFramebuffer` → no display, no signal.

At **256 MB** macOS assigns it and everything works:

```
nvrm-bars      : bar0@0x10:0x80000000+0x4000000
                 bar1@0x14:0x90000000+0x10000000     <- PCI BAR1, the real VRAM aperture
                 bar2@0x1c:0x86000000+0x2000000
kbusVerifyBar2 : count 0 (assertion gone)
rm_init_adapter -> OK        PASS 2 REACHED: the adapter is up
4 NVRMDisplay nub(s) published (nvfbheads=4)
auto-go: go(2) -> 0x0 (fPassDone 2)
IOFramebuffer : 0 -> 5       VRAM,totalsize published (16 GB)      nvrm-autogo = "up"
```

256 MB is NVIDIA's **default non-Resizable-BAR aperture**, which is why macOS
accepts it.

**How to set it.** On the host, with the card bound to `vfio-pci`:

```sh
BDF=0000:01:00.0
echo ""        > /sys/bus/pci/devices/$BDF/driver_override     # unpin
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/unbind
echo 8         > /sys/bus/pci/devices/$BDF/resource1_resize    # 8 == 256 MB
echo vfio-pci  > /sys/bus/pci/devices/$BDF/driver_override
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/bind
```

Two traps that cost hours:

* **`resource1_resize` takes a BIT INDEX, not a byte count.** `0`=1 MB, `1`=2 MB,
  … `8`=256 MB, `12`=4 GiB, `13`=8 GiB, `14`=16 GiB. Writing bytes (e.g.
  `1073741824`) decodes to bit 30 and is rejected with `-EINVAL` — which is *not*
  the kernel refusing to shrink.
* **`driver_override` must be cleared before unbinding.** While it names a driver
  the kernel immediately re-binds the device, `unbind` fails, and the resize then
  returns `EBUSY`/`ENODEV`, masking the real error.

**Do not raise this "for bandwidth."** A larger BAR makes macOS refuse the
assignment and the driver fails outright.

`UEFI → Quirks → ResizeGpuBars` / `Booter → Quirks → ResizeAppleGpuBars` do
**not** substitute for this. Tested with `-1`, `8` and `0`: the guest's OpenCore
does not touch a passed-through GPU's BAR at all — the BAR stays whatever the
host gave it.

---

## 2. The GPU must be on guest bus `0x00`

macOS uses ACPI-based PCIe enumeration (`IOPCIHPType = 0x21`). QEMU emits ACPI
hot-plug methods for PCIe root ports, macOS sees them and **defers enumeration to
runtime**, so a device behind a root port never appears at boot:

```
Bus 1, device 0: 10de:2c59    IRQ 0    BAR0/BAR1/BAR5: (not mapped)
```

…and no `10de` vendor-id anywhere in `ioreg`, while `ioreg` happily shows ~30
other PCI devices. Devices on the **root complex** are enumerated at boot with no
ACPI involvement — so put the GPU there.

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0' multifunction='on'/>
</hostdev>
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x1'/>
</hostdev>
```

`managed='yes'`, **no `<rom bar='off'/>`** (macOS wants the native option ROM),
guest bus `0x00`, and `multifunction='on'` on function 0 so the card's audio
function is visible.

This was independently reproduced by an AMD passthrough guide, which reports the
same `IOPCIHPType = 0x21` behaviour and the same fix — it is not NVIDIA-specific:

<https://forums.unraid.net/topic/197921-macos-ventura-kvm-amd-radeon-pro-wx-7100-gpu-passthrough-complete-fix-guide/>

**Same root cause, same fix, for the NIC** — a `vmxnet3` behind a root port is
invisible too, which shows up as *"an internet connection is required"* during
macOS setup. Put it on bus 0x00 as well.

---

## 3. `<video>` = `none`

```xml
<video>
  <model type='none'/>
</video>
```

With the emulated GPU present, `IONDRVSupport` loads and the firmware framebuffer
takes display index 0 away from NVRMFB. Removing it means only the NVIDIA is a
display device.

This also means there is **no QEMU screendump and no SPICE console** — you are
debugging through SSH and the GPU's own physical output. Keep SSH working.

---

## 4. USB hostdevs must be on an XHCI controller

**macOS 15 has no UHCI driver.** `kmutil showloaded` shows `AppleUSBEHCI` and
`AppleUSBEHCIPCI`, and zero UHCI. QEMU routes any full-speed (12 Mb/s) or
low-speed device to a **UHCI companion** of `ich9-ehci1`, and macOS never drives
those ports — so the device is invisible however happily QEMU reports it.
Emulated `usb-kbd`/`usb-tablet` work only because they are *high-speed* (480 Mb/s)
and enumerate on the EHCI itself.

Add a USB 3 controller and attach the hostdevs to it. XHCI has no companion
concept, so it handles all speeds natively, and macOS loads
`AppleUSBXHCI`/`AppleUSBXHCIPCI` by itself:

```xml
<controller type='usb' index='1' model='qemu-xhci'>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
</controller>

<hostdev mode='subsystem' type='usb' managed='yes'>
  <source><vendor id='0x3151'/><product id='0x4011'/></source>
  <address type='usb' bus='1' port='1'/>     <!-- bus 1 == controller index 1 -->
</hostdev>
```

Then macOS reports a second bus with the real devices on it:

```
USB 2.0 Bus (EHCI 8086:293a)   QEMU USB Tablet, QEMU USB Keyboard
USB 3.0 Bus (XHCI 1b36:000d)   <your keyboard>, <your mouse>
```

**A `USBPorts.kext` port map will not help here.** It cannot conjure a UHCI
driver, and the common `USBPorts.kext` matches ACPI names `EH01`/`UHC1`/`UHC2`/
`UHC3` — if your guest's ACPI doesn't declare those (ours doesn't), the map
matches nothing and is inert.

---

## Guest OpenCore settings

From the driver's own `app/Resources/nullmoth-setup.sh`, so this is authoritative
rather than inferred. The 1401 app applies all of it for you; this is what it does.

| Setting | Value |
|---|---|
| `NVRAM → Add → 7C436110-… → boot-args` | `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80` |
| `NVRAM → Add → … → csr-active-config` | data `43 0A 00 00` = `0x0A43` |
| `NVRAM → Delete → …` | add `boot-args` **and** `csr-active-config`, so OpenCore rewrites them every boot |
| `Misc → Security → SecureBootModel` | `Disabled` |
| `Kernel → Block` | `com.apple.iokit.IONDRVSupport`, `Strategy=Exclude`, `Enabled=true` |

Also make sure `nv_disable=1` and `-wegnoegpu` are **removed** from `boot-args` —
both hide the NVIDIA card from macOS — and that WhateverGreen's NVIDIA patches
are not fighting you.

`csr-active-config` only takes effect on reboot; `csrutil status` reports SIP
disabled only after one.

---

## Bring-up: one boot-arg

Getting the driver loaded is not enough — by itself macOS shows **no display and
no Metal**. One boot-arg fixes both, and nothing needs to run at runtime.

Add to `NVRAM → Add → boot-args` (and make sure `boot-args` is in
`NVRAM → Delete`, or OpenCore will not write it):

```
nvrmsettle=15000
```

### Why that is the whole fix

NVRM deliberately holds the IORegistry **busy** so that WindowServer's
`IOKitWaitQuiet` blocks — that is the mechanism which sequences WindowServer to
start *after* the driver has armed the display. The hold has a **fixed 40 s cap**,
but the schedule it races is **500 ms, 10 s or 100 s** depending on `bar1Placed`
(`kexts/NVRM/NVRM.cpp:323`):

```c
fAutoGoSettleMs = bar1Placed ? 500 : 100000;
{ uint32_t ms = 0; if (PE_parse_boot_argn("nvrmsettle", &ms, sizeof(ms))) fAutoGoSettleMs = ms; }
```

| `bar1Placed` | auto-go | vs 40 s cap | result |
|---|---|---|---|
| true (8 GB BAR, bare metal) | `+500 ms` | inside | hold outlives bring-up → **Metal desktop** |
| false, default | `+100 s` | **outside** | cap fires first → WindowServer starts early → no Metal |
| false, **`nvrmsettle=15000`** | `+15 s` | inside | hold outlives bring-up → **Metal desktop** |

`placeLargeBar1()` is always false here — macOS will not assign a Resizable BAR
larger than 256 MB — so the default 100 s path always loses the race. Overriding
the settle time moves the bring-up back inside the window without needing the
8 GB BAR the README asks for.

### Verified result

```
auto-go: go(2) in 15000 ms on its own thread (BAR1 not placed); registry held busy until the display is armed (cap 40 s)
boot hold RELEASED (display armed)        <- not "by the 40 s cap"
PASS 2 REACHED: the adapter is up
4 NVRMDisplay nub(s) published

debug.nvaccelfb:   1     <- self-armed by the driver; no sysctl was run
debug.nvrmfb_agdc: 1     <- likewise
nvrm-boot-hold:    "display armed"
MTLCopyAllDevices -> 1   NVIDIA GeForce RTX 5080 Laptop GPU (NVMTL over NVK GB203-B)
system_profiler:         Metal Support: Metal 3
```

**The driver does all of it itself.** `onCountGrewLocked()` restores
`MetalPluginName` and sets `IOGLBundleName=AppleMetalOpenGLRenderer` once the
display is armed, so `debug.nvaccelfb`, `debug.nvrmfb_agdc` and the WindowServer
restart are all unnecessary — they were workarounds for a driver that had already
lost the race.

### About the boot daemon in this directory

`nullmoth-desktop.sh` / `com.nullmoth.desktop.plist` are the old three-gate
workaround. **They are not needed with `nvrmsettle` and should stay disabled**
(`com.nullmoth.desktop.plist.disabled`). Worse, running the daemon's WindowServer
restart is actively harmful now: `nvmtl-allow.txt` lists WindowServer as
`!WindowServer` (allowed *when armed*), so a restart hands it a Metal path
mid-session and the UI stops updating. Removing the `-WindowServer` deny is safe
only because the boot-hold now sequences WindowServer correctly.

---

## Verification

```sh
# driver loaded, 4 kexts
kmutil showloaded | grep nullmoth

# driver reached pass 2 and claimed the GPU
ioreg -l -w0 | grep -o '"nvrm-autogo" = "[^"]*"'      # expect "up"
ioreg -l -w0 | grep -o '"nvrm-bars" = "[^"]*"'        # must contain bar1@0x14

# a framebuffer and a display exist
ioreg -rc IOFramebuffer | grep -c '+-o '              # expect >= 1
ioreg -rc IODisplay | grep -c '+-o '                  # expect 1

# the display itself
system_profiler SPDisplaysDataType                    # expect your monitor + "Metal Support: Metal 3"
```

`"nvrm-bars"` is the single most useful diagnostic: it must contain
**`bar1@0x14`**. If it shows only `bar0@0x10` and `bar1@0x1c`, you are hitting the
BAR1 problem in section 1 — no need to look further.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `10de` in `ioreg`; `IRQ 0`, BARs `(not mapped)` | GPU behind a root port | move to guest bus `0x00` (section 2) |
| `nvrm-autogo = "go(2) failed"`, `rm_init_adapter -> FAILED` | BAR1 too large | set 256 MB (section 1) |
| `kbusVerifyBar2_… returned garbage`, `NV_ERR_MEMORY_ERROR` | same as above | same |
| `bar1: no Resizable BAR capability` | GPU behind a **conventional PCI** bridge — no extended config space, so the ReBAR capability at `0x134` is unreadable | put it on bus `0x00` instead |
| `nvrm-autogo` stuck at `"scheduled +100 s"` | you are looking too early — pass 2 is ~100 s after NVRM arms | wait, then re-check |
| `AGDC: no PCI device or no framebuffer yet` | gate 1 applied before the driver was up | wait for `"nvrm-autogo" = "up"` |
| Driver up, `IOFramebuffer` ≥ 1, but `IODisplay` = 0 | nothing has re-enumerated the display | gate 2 (WindowServer kick) |
| No `Metal Support` line, `MTLCopyAllDevices()` → 0 | `MetalPluginName` is withheld by design | gate 3 |
| `virsh console` does nothing | `<serial>` retargeted to a file for log capture | restore `type='pty'` |
| Passed-through USB device absent from macOS | device on a UHCI companion | XHCI (section 4) |
| Passed-through USB device has no function files | USB tooling/port-map mismatch | see appendix C |

---

## Metal: working now — what the fix actually changed

The desktop is **GPU-composited and Metal 3 is available to applications**, with
no runtime steps. That is the intended behaviour; getting there needed only
`nvrmsettle` (above), which moves the driver's bring-up back inside the 40 s
boot-hold so WindowServer genuinely waits for it.

The earlier analysis in this document concluded the desktop was *not* supposed to
run on Metal. **That was wrong**, and the correction matters: the README is
explicit that WindowServer is meant to composite through the accelerator —

> *"Your NVIDIA card drives the desktop, Metal apps, games, Core ML/MPS, and
> OpenCL — the way an Apple-supported GPU does."*
> *"NVAccel the accelerator WindowServer composites through"*
> *"the AMFI args let WindowServer load the driver bundle"*

So the fix is not a workaround. It restores the sequence NVRM was designed to
enforce and which the 100 s slow path was defeating.

---

## Performance: the compositor is squeezed into a 192 MB window

**Fixed first by the conf (3-4x), then bounded by the BAR.** Two findings, in the
order they matter.

### The shipped `nvrm610.conf` throttles the compositor

`/Library/GPUBundles/nvmtl/nvrm610.conf` ships from the tarball with very
conservative VRAM values, against the driver's own code defaults:

| knob | shipped | code default (`plugin/nvmtl_vk.c`) |
|---|---|---|
| `NVMTL_VRAM_WS_NONIMAGE_MB` | **0** | `NVMTL_VRAM_NONIMAGE` = **2655** |
| `NVMTL_VRAM_HEADROOM_MB` | **256** | `NVMTL_VRAM_HEADROOM_DEFAULT` = **1024** |
| `NVMTL_RES2_WS` | **0** | enabled — returns the full VRAM |

`NVMTL_RES2_WS=0` is the important one: it disables the branch in
`nvmtl_vk_working_set()` that short-circuits to `nvmtl_vk_vram_bytes()` (the whole
card), leaving a budget-derived working set instead. With the defaults restored:

| | shipped conf | code defaults |
|---|---|---|
| dragging a window | **16-21 fps** | **58-80 fps** |
| idle | ~137 fps (never idles) | **0 fps** (correctly idle) |
| refusals | none | none |

Note mapped VRAM was **unchanged** (175/192 MB) — the win is not from using more
memory, it is from the plugin no longer thrashing its allocation decisions. To
apply it, edit the conf and **restart WindowServer** (the knobs are read at plugin
load, `plugin/NVMTLObjects.m:100`), which costs a logout.

### The remaining ceiling is the 256 MB BAR

With the conf fixed the desktop is usable, but the surface budget is still 192 MB
and it sits at **179 MB used — 93% full, ~13 MB free**. That has a visible
consequence: **Steam regresses it**, and closing Steam recovers it. Steam's UI is
Chromium-based and GPU-composited, so it competes for the same VRAM grants, and
13 MB of headroom is not enough. There are no `REFUSED` messages — the budget is
*crowded*, not exhausted.

So the ordering of causes is:

1. **conf policy** — self-inflicted, fixed above, worth 3-4x
2. **the 192 MB budget** — imposed by the 256 MB BAR that macOS will not exceed;
   not fixable here (see [Appendix C](#appendix-c--why-256-mb-and-how-it-was-found))
3. **the Metal→NVK translation** — inherent to the driver; the residual CPU cost

Measured along the way, for reference:

| measurement | value | native 5080 laptop |
|---|---|---|
| GPU copy, `Private` (VRAM) | 423-467 GB/s | ~700-900 GB/s |
| GPU copy, `Shared` (system RAM) | 7.8 GB/s | *(normal for a dGPU — Shared is system RAM by definition)* |
| GPU fma (Metal) | ~5.3 TFLOPs fp32 | ~30-50 TFLOPs |
| Geekbench 7 Metal | ~100,000 | — |

**Corrections this section went through**, since the reasoning matters more than
the conclusion: an earlier revision claimed the desktop was *not* BAR-related. That
was based on benchmarking only `MTLResourceStorageModePrivate` buffers, which
bypass the placement policy entirely. A later revision then over-read the slow
`Shared` number as a smoking gun — but `Shared` on a discrete GPU is system RAM by
definition and would measure the same on real hardware. The BAR link is real, but
it comes from the **192 MB grant budget and its 93% occupancy**, not from
bandwidth.

## Display modes: 165 Hz at native resolution only

The driver publishes 26 modes, but only **one** at native resolution:

```
  3440x1440 @ 165.0 Hz        <- the only native-resolution mode
  1920x804  @ 165.0 Hz  ·  2048x858 @ 165.0 Hz  ·  1720x720 @ 165.0 Hz
  1280x720  @  60.0 Hz  ·  1280x960 @ 60.0 Hz   ·  1024x768 @ 60.0 Hz ...
```

NVRMFB builds its modes from the native timing (hence the scaled 165 Hz variants)
plus a few VESA modes at 60-75 Hz, and **never a lower refresh at native
resolution**. So "I can only pick 165 Hz" is a driver mode-list limitation, not a
panel limitation. Testing a lower compositing load is still possible at a
reduced resolution (e.g. `1920x804 @ 165`, or `1280x720 @ 60`).

## Changing display resolution wedges the display — and can panic the kernel

> ⚠️ **Treat mode changes as crash-risk, not just inconvenient.** A display mode
> change was in flight immediately before a **kernel panic** on this machine
> (`NVAccel: DM displayModeWillChange` → `NVRM-fb: setAttribute 'spwr'` →
> `Ticket lock ... unexpectedly owned @lock_ticket.c:143`). No backtrace survived
> (the panic handler nested), so causation is unproven — but see
> [UPSTREAM-REPORT.md](UPSTREAM-REPORT.md) Finding 5. Two `Kernel-*.panic` reports
> exist in `/Library/Logs/DiagnosticReports/`.

Selecting another mode leaves a **blank background with a live cursor**.
WindowServer does **not** crash — the pid is unchanged, there is no crash report,
and the session stays logged in — but it goes **idle**:

```
WindowServer cputime  16:07.18 -> 16:07.19 over 6 s     (0.01 s in 6 s = not spinning)
```

`IOFramebuffer` count rises (8 -> 10), so new framebuffers were created for the
new mode, but nothing is presented. Recovery is a WindowServer restart, which
costs a logout:

```sh
sudo launchctl kickstart -k system/com.apple.WindowServer
```

The mode itself is fine afterwards — selecting a different resolution and then
querying it shows the display already back at `3440x1440 @ 165`, so the damage is
to the presentation path, not the mode. Worth reporting upstream; the same wedge
is what `nullmoth-desktop.sh` used to recover from, which is one more reason to
leave that daemon disabled.

---

## The allow-list order bug (fixed here, upstream elsewhere)

**Symptom:** after arming Metal, the desktop **freezes** while the **cursor still
moves**.

**Cause — the shipped `nvmtl-allow.txt` makes its own WindowServer rule dead
code.** `nvmtl_allowed()` in `plugin/NVMTLDevice.m` stops at the **first matching
line**:

```c
if (*p == '-') { ...deny... }                     // '-' = hard deny, returns false
if (*p == '!') { armedOnly = true; ... }          // '!' = allow, but only when armed
if (strcmp(p, "*") && strcmp(p, me)) continue;    // match "*" or the exact name
...
ok = true; break;                                 // FIRST match wins, then stop
```

The shipped file is:

```
# rung 3: everyone; -Name denies
*
!WindowServer        <- unreachable: the "*" line above already matched
```

So `!WindowServer` never applies, `*` grants WindowServer the Metal plugin as soon
as `MetalPluginName` is advertised, and WindowServer switches to Metal
compositing — which this driver cannot sustain, so the UI stops updating.

**Fix — put the deny FIRST:**

```
-WindowServer
*
```

**Verify it empirically, without rebooting.** Copy a Metal test binary to a file
*named* `WindowServer` and run it — the deny is by `getprogname()`:

```sh
sudo cp /tmp/metalrun /tmp/WindowServer && /tmp/WindowServer   # -> "no Metal device"
/tmp/metalrun                                                  # -> device, compute OK
```

**Do not use `lsof` as the signal.** The Metal framework `dlopen`s the plugin
bundle to ask it for devices *even when the allow-list refuses*, so
`lsof -p <WindowServer> | grep NVMTLDriver` shows a mapping either way. The
authoritative test is the name check above.

**Consequence — the honest answer to "can everything render on Metal?":** not in
this configuration. WindowServer must stay off it or the desktop freezes, and
because the `nvaccelfb` gate is global (see the root cause above), leaving it off
means **no process gets Metal at all** — not games, Core ML or OpenCL either. It
is an awkward all-or-nothing: working desktop XOR GPU compute. On a machine where
macOS grants the large BAR the README asks for, the boot-hold wins its race and
WindowServer composites through NVAccel, which is the intended behaviour.

## Why a large BAR cannot work here — measured, and correcting an earlier claim

**An earlier revision of this document said macOS "will not assign a Resizable BAR
larger than 256 MB". That is wrong.** macOS *does* assign large BARs — it just
never publishes a descriptor for them, and the driver's entire BAR table is built
from those descriptors.

### macOS assigns a big BAR happily

Host BAR1 raised, VM booted, guest checked (QEMU's `info pci`, i.e. the config
space macOS programmed):

| host BAR1 | macOS assigned | where |
|---|---|---|
| 256 MB | ✅ `0x90000000` | **below 4G** |
| 2 GiB | ✅ `0x1000000000` | above 4G |
| 4 GiB | ✅ `0x1000000000` | above 4G |

The ReBAR capability is also read correctly at every size
(`bar1: Resizable BAR capability @0x134 says BAR1 = 2048 MB` / `4096 MB`).

### But no descriptor is published for a BAR placed above 4G

`readBARs()` builds the driver's whole table from `getDeviceMemoryWithIndex()`
descriptors, and it logs every descriptor it cannot match. At 2 GiB and 4 GiB the
list contains no large aperture at all:

```
aperture idx 1 phys 0x10 size 0x4: no BAR register matches        (config-space residue)
aperture idx 3 phys 0x6000 size 0x80: no BAR register matches     (I/O BAR5)
aperture idx 4 phys 0x84000000 size 0x80000: no BAR register matches  (audio function)
BARS bar0@0x10:0x80000000+0x4000000 bar1@0x1c:0xf0000000+0x2000000
                                                  ^ BAR3 again, BAR1 absent
```

The rule is **address, not size**: below-4G placement yields a descriptor, above-4G
placement does not. Consequences chain immediately:

* `bars[NV_GPU_BAR_INDEX_FB]` falls back to **BAR3** (a 32 MB non-VRAM window)
* the RM is handed that as its VRAM aperture → `kbusVerifyBar2` → `go(2) failed`
* `nvrmDiscoverBar1()` also reads descriptors, so **`fBarLen` is 0** → `budget: 0`
* the result is **worse than 256 MB**: no display, no Metal, `Metal devices: 0`

`placeLargeBar1()` also failed at both sizes with `bar1: parent root port not
found` — we are on bus 0 by necessity (section 2), and that function requires a
bridge parent. So the driver cannot place it itself either.

### The budget therefore cannot be raised

```c
const SInt64 budget = (fBarLen >= (4ull << 30) ? fBarLen / 2 : NVRM_VRAM_BAR1_BUDGET);
```

`fBarLen` comes from a descriptor, descriptors do not appear above 4G, and a
≥4 GiB BAR cannot be placed below 4G. **192 MB is a hard ceiling here**, and the
gate threshold (4 GiB) sits exactly where macOS stops publishing.

### What the QEMU side is *not* to blame for

Measured from the running domain — the room above 4G already exists and is ample:

```
dev: q35-pcihost
    pci-hole64-size   = 34359738368 (32 GiB)
    below-4g-mem-size =  2147483648 (2 GiB)
    above-4g-mem-size = 32212254720 (30 GiB)
```

So patching QEMU's hole size would fix nothing — the BAR is assigned, in the hole,
and the missing piece is macOS's descriptor. Likewise OpenCore's `ResizeGpuBars`
only affects the **host** firmware and has no effect on a passed-through device
(section 1).

### The one avenue that could still work

If macOS could be made to publish descriptors for above-4G BARs, a large BAR would
work and the budget would jump to `fBarLen/2` (2 GiB at a 4 GiB BAR, 4 GiB at 8).
The plausible lever is **ACPI**: macOS learns its MMIO windows from the host
bridge's `_CRS`, so an **OpenCore ACPI patch/SSDT that declares the above-4G window
explicitly** might make IOPCIFamily publish the descriptor. That is untested, and
it is the only remaining path — everything on the QEMU side is already correct.

**Until then: keep BAR1 at 256 MB.** Larger values do not degrade gracefully, they
break the driver completely (no display, no Metal).

## Testing methodology (so results are comparable)

Everything below was measured with a repeatable harness, in `vms/macos/`:

| file | what it does |
|---|---|
| `dragload.m` | opens a Metal-backed window and **moves it continuously**, reproducing the compositing load of a window drag without a human. Reports moves/s and compositor flips/s. **Known limitation:** its content does not actually redraw (`0 redraws` — `updateLayer` never fires despite a layer-backed view), so it exercises window *movement* only. That is enough for consistent A/B comparison (it produced every number below) but it is **lighter than a real drag** and does **not** reproduce the ~0.5 s drag-start stall. Reproducing that needs a human drag, or a fix to the redraw path. |
| `bench.sh` | the one procedure per test: check the session is ready, run `dragload`, report **flips, WindowServer CPU per flip**, and the grant/park/refusal deltas |
| `surfbench.m` | times IOSurface + Metal-texture creation (the surface path) |
| `shaderbench.m` | times first-use shader compilation through the translator |

Two methodology traps that produced **wrong answers** before being fixed — both
worth knowing:

1. **`console user == <you>` is not "a session exists".** WindowServer restarts
   leave it set while the desktop is still coming up, and a load then measures a
   half-initialised session: **~10 fps and ~114 MB mapped** instead of ~108-133 fps
   and ~152-175 MB. `bench.sh` now requires the console user **and** the Dock **and**
   session-sized VRAM, and aborts rather than reporting a bogus number.
   **Do not test for the Dock with `pgrep -x Dock`** — the session's Dock reports
   its comm as the *full path*
   (`/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock`), so an exact-name
   match never succeeds and every run aborts with a false "no session". Match the
   path (`pgrep -f "Dock.app/Contents/MacOS/Dock"`) instead. That single mistake
   invalidated several runs here before it was caught.
2. **Auto-login is a boot-time behaviour only.** A WindowServer restart drops to the
   login window and it does **not** come back; a **reboot** does (session up in
   ~40 s). So conf/plugin changes are tested by editing the conf and **rebooting**,
   not by restarting WindowServer. Auto-login needs **both**
   `defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser <user>`
   **and** `/etc/kcpassword` — the latter only the System Settings route writes
   (System Settings → Users & Groups → "Automatically log in as"), because it needs
   the password.

Baseline on this machine (post-reboot, code-default conf, 20 s load):

```
flips ~2160-2214,  WindowServer ~4.26-4.34 ms CPU per flip,  ~108-133 fps
grants +0,  parks +0,  refusals +0,  mapped 155-157/192 MB
```

That is the state this document leaves the machine in: driver up, display armed,
Metal 3 available, zero allocation thrash, and the compositor sustaining ~110 fps
under a synthetic drag load.

## What was verified, and what it rules out

| claim | evidence | verdict |
|---|---|---|
| Frames reach the panel **zero-copy** | `nvaccel_iop_flips` 3160, `iop_flip_hit` 3154, `iop_flip_novram/refused/stale` all **0**, `nvrm-flip: "on"` | ✅ optimal |
| The **copy** path (with its visible flip-home) is in use | `nvaccel_iop_flip_home: 0` | ❌ never used |
| Shader caches are cold, so first use recompiles | WindowServer has **70 MB / 2047 files** in `nvmtl/aircache`, plus `spvcache` and `nvmtl-mesa`; 128 MB total | ❌ caches warm |
| First-use compilation is expensive anyway | `shaderbench`: **median 17.7 ms, p90 32 ms, max 203 ms** per distinct shader — so a drag needing several new variants can plausibly total ~0.5 s | ✅ plausible cause of the drag stall |
| Surface allocation is the drag stall | `surfbench`: ~8 ms per surface, but the grant counters **did not move** and the import failed with `NVRM_SS_NO_VRAM` (`0x80000005`) — it exercised a *CPU-backed* path, not the compositor's | ⚠️ inconclusive |
| The drag stall is reproducible without a human | `dragload` never redraws content, so it cannot reach the drag-start path | ❌ still open |
| The 192 MB grant budget is exhausted | `budget spent: 0` — the budget check **never fired**; the failures are `OVERLAPS THE CONSOLE` → park → retry | ❌ wrong theory |
| Allocation thrash happens | **3779** `parking it and rolling again`, **474** `REFUSED` (in one VM boot, before the conf fix) | ✅ real |
| The stale/blinking image is a driver bug | it is the compositor correctly not re-presenting when idle; the panel keeps the last buffer flipped. It appears after a **WindowServer restart** because new content is only presented on change | ❌ benign |
| `debug.nvrmfb_flip_latch` / `flip_interval` are worth tuning | tested live under a real drag: **16-21 fps with them, 16-21 without** | ❌ no effect |

### ⚠️ `NVMTL_HWPOOL=1` — do not enable

Setting `NVMTL_HWPOOL=1` in the conf correlates with a **kernel panic**. It installs
Apple's private `MTLIOAccelResourcePool` / `setHwResourcePool:count:` via
`objc_msgSend` (`plugin/NVMTLDevice.m:319`), and on the boot where it was enabled
the guest panicked:

```
NVAccel: DM displayModeWillChange
NVRM-fb: setAttribute 'spwr' value 3758097168 -> 0xe00002c7
Debugger called: <panic>
Nested panic detected - entry count: 2
Ticket lock 0xffffff8010f3d480 is unexpectedly owned by thread ... @lock_ticket.c:143
```

The panic report is **empty of any stackshot** — *"no on disk or sleep/wake failure
panic stackshot found"* — because the panic handler itself panicked (nested panic).
Two `Kernel-*.panic` reports exist, and the log shows a **display mode change** in
flight immediately before the panic. Causation is not proven (no backtrace), but
the flag is private-API plumbing with no measured benefit, so the recommendation
stands: leave it unset. It is reverted here.

**Corollary, and it matters more than HWPOOL:** display mode changes are not merely
the "wedges the display" bug documented earlier — they are the context of a
**kernel panic**. Treat changing resolution as a crash-risk operation on this driver.

## ROOT CAUSE of the remaining stall: the VRAM grant budget is exhausted

This explains the "first interaction sticks for a second, then it is smooth"
behaviour, and why it is worse with Steam running.

**The budget is full and every allocation is now refused.** Measured live, via the
driver's own `debug.nvrmfb_vramtest` knob (which grants N x 8 MB through
`vramGrant`) — every size from 8 MB to 128 MB was refused:

```
nvAllocVram(8323072): REFUSED
vramtest: holding 0 x 8 MB            <- nothing succeeded, at any size

this boot:  parks 5136   park-ceiling hits 5137   REFUSED 771   grants 12
```

**Twelve** successful grants in an entire boot, against **5137** park-ceiling hits.

### Why: `gParkedForever` is a permanent leak

`nvAllocVram` handles an allocation landing on the console/scanout range by
*parking* it — holding the memory mapped — and retrying. The array is literally
named for it, and it is **never released**:

```c
static struct { struct NvKmsKapiMemory *m; void *k; NvU64 n; } gParkedForever[24];
static volatile SInt64 gVramParkedBytes = 0;
...
gParkedForever[gNParkedForever++] = {m, k, want};    // held
OSAddAtomic64((SInt64)want, &gVramParkedBytes);      // and counted against the budget
```

There is **no free path, no reset path, and no sysctl** — every reference to
`gParkedForever` and `gVramParkedBytes` in the tree is either the declaration, the
store, or the budget arithmetic. And the budget is:

```c
SInt64 before = OSAddAtomic64((SInt64)want, &gVramMappedBytes) + gVramParkedBytes;
if (before + (SInt64)want > budget) { ...REFUSED — BAR1 budget spent...; return false; }
```

So leaked bytes are indistinguishable from live ones, forever.

### The arithmetic, and why uptime makes it worse

| | value |
|---|---|
| mapped shortly after boot | ~153-157 MB |
| mapped after a few hours | **185 MB** |
| park ceiling (`NVRM_VRAM_PARK_CEILING`) | 24 MB |
| grant budget (`NVRM_VRAM_BAR1_BUDGET`, 256 MB BAR) | 192 MB |

The ~28-30 MB of growth from boot to now matches the ~24 MB park ceiling, and
`185 MB live + up to 24 MB leaked > 192 MB budget` is exactly the condition that
refuses everything. Nothing recovers it at runtime.

### What this means in practice

* **The stall is an allocation failure, not a slow path.** When something needs a
  new surface and the budget is spent, `nvAllocVram` refuses and the client must
  retry or fall back — that is the one-second stick.
* **Steam makes it worse** because it adds live VRAM pressure on top of the leak,
  reaching the ceiling sooner.
* **It degrades with uptime**, because the leak only grows.
* **A reboot clears it** — that is the only reset, since no runtime path frees
  parked memory.

**Practical mitigations available today:**

1. **Reboot when the desktop starts sticking.** It resets the leaked ~24 MB and
   returns the budget to ~155 MB used. This is the single effective workaround.
2. **Quit Steam when not gaming** — it is the largest live consumer.
3. Nothing else: the budget cannot be raised (256 MB BAR ceiling, see
   [Appendix C](#appendix-c--why-256-mb-and-how-it-was-found)), and the leak cannot
   be freed without a driver change.

Upstream, this is a strong report: the parking heuristic leaks budget permanently,
so on a small-BAR system the driver degrades to zero allocatable VRAM. Reclaiming
parked entries under pressure (they are rejects — the retry may succeed once other
grants are released) would fix it. See
[UPSTREAM-REPORT.md](UPSTREAM-REPORT.md) Finding 9.

## ISOLATED: OpenCore is what writes the garbage BAR address

Four-way isolation with the SAME hardware (machine `pc-q35-10.2`, same OVMF
`edk2-x86_64-code.fd`, same `-cpu` args, same 32 GiB RAM, same GPU hostdevs, same
8 GiB host BAR1):

| guest | BAR1 address | QEMU |
|---|---|---|
| **Linux** (Alpine, twin XML) | `0x1000000000` | ✅ runs |
| **Windows** (`win11-stealthy-dgpu`) | `0xe000000000` | ✅ runs |
| **macOS with OpenCore disk removed** | — | ✅ runs, **no crash** |
| **macOS with OpenCore** | `0x8408400000000000` | ❌ crash |

**So it is not QEMU, not vfio, and not OVMF** — OVMF places the BAR correctly (the
Linux and no-OpenCore runs prove it). OpenCore, or something it loads, overwrites
BAR1 with a non-canonical address, and QEMU then dies trying to map it.

**And it is not a kext:** with *every* entry in `Kernel -> Add` disabled, the macOS
guest still crashes. So it is OpenCore's own EFI-side code, not Lilu /
WhateverGreen / VirtualSMC.

Ruled out as the trigger:

* `ResizeGpuBars = -1` — still crashes, so it is not the ReBAR *write* path
* `ResizeGpuBars = 13` — same
* `DevirtualiseMmio = true` — same
* `phys-bits=40` added to the `-cpu` argument — same
* `q35-pcihost.pci-hole64-size = 256 GiB` — same

Remaining OpenCore-side suspects to bisect (in `EFI/OC/`):

* `Drivers/OpenRuntime.efi` — the runtime driver that owns the memory map; the
  most likely place for MMIO/PCI resource handling
* `ACPI/SSDT-DTGP.aml` — GPU/device-tree helper
* OpenCore itself (version-specific) — an older or newer build may differ

### How AMD macOS passthrough handles this: it does not — it avoids it

Per the AMD OS X administrator, the standard AMD Resizable-BAR recipe is:

```
Booter -> Quirks -> ResizeAppleGpuBars = 0     # macOS is given a SMALL BAR (1 MB)
UEFI   -> Quirks -> ResizeGpuBars      = -1
Remove npci=0x2000 / npci=0x3000 — "it'll conflict with Above 4G decoding"
```

Even with ReBAR enabled in the BIOS, **macOS is deliberately given a small BAR**,
because macOS's own PCI resource allocation cannot be trusted with a large one.
This is a **macOS limitation, not an NVIDIA one** — and our boot-args contain no
`npci=`, so that specific conflict does not apply here.

It also explains the bare-metal/VM split cleanly: the NullMoth installer sets
`ResizeAppleGpuBars = -1` (macOS sees the full BAR), which works on real hardware
because the motherboard firmware has already assigned the BAR and macOS leaves it
alone. In a VM, macOS re-derives the assignment and gets it wrong.

## CAN IT BE FIXED AT THE LIBVIRT XML LEVEL? No — and one of my tests was invalid

Short answer: **no**, because what blocks us is how **QEMU generates ACPI**, and the
libvirt XML cannot change that. But the honest reason is more specific, and it
includes a correction.

### What `placeLargeBar1()` actually requires

Read from the source, in order. It needs a bridge **two levels up** from the GPU:

| # | requirement | behind a root port | on the root complex (our case) |
|---|---|---|---|
| ① | grandparent is an `IOPCIDevice` | ✔ | ✘ host bridge's parent is not one |
| ② | its PCIe port type **= 4 (Root Port)** | ✔ | ✘ host bridge is not a root port |
| ③ | secondary **and** subordinate bus both == ours | ✔ | ✘ host bridge spans 0–255 |
| ④ | 64-bit prefetchable window on it | ✔ | would be satisfiable |

It needs all of that because it **reprograms the parent bridge's prefetchable window**
(`rp` 0x24/0x28/0x2c) to cover the relocated BAR1/BAR3. A bridge that spans all of PCI
can't be reprogrammed — that would move every other device. Hence the root-port
restriction, which is correct engineering for the topology it was written for.

### The XML options, and why each fails

| XML change | enumerated by macOS | ReBAR capability readable | verdict |
|---|---|---|---|
| GPU on bus 0 (current) | ✅ | ✅ | driver works, **placement impossible** ✗ |
| GPU behind a PCIe root port | ❌ **invisible** | — | ✗ |
| GPU behind a conventional PCI bridge | ✅ | ❌ **unreadable** | placement impossible ✗ |

The third row is a hard limit: conventional PCI has only **256 bytes** of config
space, and the Resizable BAR capability sits at **`0x134`**. That is why the very
first attempt in this project logged `bar1: no Resizable BAR capability`.

### The correction: `hotplug='off'` never reached QEMU

I previously reported testing "GPU behind a root port **with hotplug off**" and
concluded the enumeration barrier survives it. **That test was invalid.** Verified on
the running domain:

```
hotplug=off occurrences in the QEMU cmdline: 0
qemu-system-x86_64 -device pcie-root-port,help   ->  no `hotplug` property exists
```

libvirt accepted `hotplug='off'` on the controller and silently dropped it; QEMU's
`pcie-root-port` has no such property. So the GPU was invisible **with hotplug fully
enabled** — the hypothesis that disabling hotplug would let macOS enumerate a
root-port device is **untested**, not disproved.

**What this changes:** the root-port route is not formally closed. What *is* closed is
that it cannot be reached from libvirt XML, because QEMU offers no property for it —
`IOPCIHPType = 33` is produced by ACPI that QEMU emits, and the XML has no lever over
that. Reaching it needs either a QEMU patch or an ACPI override (OpenCore's
`ACPI -> Add`), both of which remain open.

**Lesson, again:** a config change must be verified at the consumer, not the writer.
libvirt accepting an attribute says nothing about QEMU receiving it. Same failure mode
as the `<qemu:commandline>` block that was deleted by a cleanup regex and went
unnoticed for hours.

## Driver 1.0.9 installed and verified (was 1.0.6)

Updated to the newest release, `v1.0.13` (release name: *"1401 Mac 1.0.13
(driver package 1.0.9)"*). SHA256 of `nullmoth-nvidia-1.0.9.tar.gz` matched
`9dbfdb1b…` from the release's `SHA256SUMS.txt`.

**The release's own `VALIDATION.json` is the useful part** — it states the scope:

```
scope:                    "Installer and app maintenance only; no additional GPU or application ..."
changed_payload_files:    MANIFEST.txt, uninstall.sh, install.sh, SHA256SUMS
unchanged_payload_files:  46
nvidia_binary_base:       1.0.8
```

Confirmed by comparing binaries against 1.0.6:

| kext | 1.0.9 | 1.0.6 | |
|---|---|---|---|
| `NVRM` | 16750224 | 16750224 | **identical** — the BAR code is unchanged |
| `NVRMFB` | **145824** | 144424 | **changed, +1400 B — the vblank fix** |
| `NVRMAGDC` | 50872 | 50872 | identical |
| `NVAccel` | 231560 | 231560 | identical |

`nvrm610.conf` **still ships the conservative values**, so the conf fix remains
required, and the installer still resets it — re-applied after install.

### Result on the baseline

```
autogo="up" (24 s)   IODisplay=1   budget=192MB   kexts=4   NVRMFB=145824
nvrm-boot-raster = "head0 165.000Hz"     <- new, and correct for the native panel
dragload: 14.0 s, 9227 moves (659/s), 0 redraws
compositor flips: 1627 -> 116.2 fps      WindowServer 7.12 s -> 4.37 ms/flip
grants +0   parks +0   refusals +0
```

That matches or beats 1.0.6 (110.6 fps / 4.34 ms) with zero parks and refusals.
**The BAR ceiling is unchanged** — `NVRM` is byte-identical, so the root-port gate
at `NVRM.cpp:746` behaves exactly as before, and the budget stays 192 MB.

### Testing note

The first benchmark after the reboot reported **0 flips**, which looks alarming but
is a false alarm: the desktop session had not finished coming up (uptime ~1 minute;
Dock and WindowServer present but the compositor not yet presenting). Re-running once
the session settled gave the numbers above. Do not read a 0-flip result as a
regression without checking session readiness first — `bench.sh` gates on the
console user, Dock, and mapped VRAM, but a freshly booted machine can still slip
through that gate.

### What to check by eye

`NVRMFB`'s change is *"every lit head gets its real vblank, not only heads that
latch a flip"* — a presentation fix, which is the first upstream change aimed at the
symptoms reported from this setup: the screen flashing between an old and the
current frame, the stale idle image, and the white wallpaper since first setup.
Those cannot be measured from here; they need a human looking at the screen,
especially with Steam running and in No Man's Sky.

## INDEPENDENT VERIFICATION: NVRM.kext cannot be built from public sources

A separate agent, given only the repo and no knowledge of our conclusions, was asked
to establish whether `NVRM.kext` is buildable. It reached the same answer by a
different route and with harder evidence. Its three independent gaps, each
sufficient on its own:

**1. No script compiles the BAR code.** The symbols are located precisely:
`placeLargeBar1` declared `kexts/NVRM/NVRM.cpp:120`, defined `:679`, called `:304`;
`readBARs` declared `:119`, defined `:818`, called `:305`;
`nvrmDiscoverBar1` at `kexts/NVRMFB/fb/nvrm-fb.cpp:1123`. **Every `.sh` in the repo
was checked: zero compile `NVRM.cpp` or `nvrm-fb.cpp`.** `build/` produces only
`NVAccel.kext`, `NVRMAGDC.kext`, the Metal plugin, the translator and Mesa NVK. The
only NVRM/NVRMFB mentions in any script are kext-name lists in install/uninstall
scripts. Nothing in `build/` ever references the `kexts/` tree.

**2. NVIDIA's public ogkm has no Darwin target at all.** `grep -ri darwin` over the
whole tree = **0 hits**; `README.md:1` calls it "NVIDIA **Linux** Open GPU Kernel
Module Source"; `utils.mk:123-137` branches only for Linux/FreeBSD/SunOS;
`nvport/debug.h:277-293` ends in `#error "Unsupported target OS"`. Vestigial Apple
code exists (`cpuopsys.h:108` `NV_MACINTOSH`) but is inert — its only consumer in
the tree is a log buffer size.

> **Hard proof it is not a port:** `make TARGET_OS=Darwin -C src/nvidia` **exits 0**
> and writes `_out/Darwin_x86_64/nv-kernel.o` (18 MB) — whose magic bytes are
> `7f 45 4c 46` = **ELF, a Linux object, not Mach-O**. `TARGET_OS` only renames the
> output directory; the flags remain Linux kernel flags. A false positive.

**3. The scripts depend on unpublished private artifacts.** `accel_build.sh:15`
reads `$NV/_out/Darwin_x86_64/compile_cmds.sh`; run on a clean macOS guest against a
clean stock ogkm clone it **exits 1** (`head: ... No such file or directory` then
`RMDEFS[@]: unbound variable`) before reaching any compiler. **`compile_cmds` has 0
hits in the entire ogkm tree** — stock ogkm produces `nv-kernel.o`, never that file.
The same path is required by `kexts/NVRM/rmcc.py:7`.

**The decisive artefact:** `kexts/NVRM/rmcc.py:6` says *"`build-nvrm.sh` runs with
HOME=<its home>; OGKM names the RM tree"* and `:3` mentions *"The kext links it
beside **libnvkernel.a**"*. **Neither `build-nvrm.sh` nor `libnvkernel.a` exists in
the repo or in ogkm, and `rmcc.py` is referenced by no build script.** The NVRM kext
is produced by a private script, linking a private static library, and neither is
published.

Also: five build scripts hardcode private `$HOME/nvmtl-build/...` paths;
`build_agdc.sh` is not even listed in the README; and `git ls-files` shows 495 files
with **zero** `.kext`/`.dylib`/`.o`/`.a` — prebuilt kexts exist only as release
binaries, which is a download, not a build.

**Verdict: `NVRM.kext` is obtainable publicly only as a prebuilt binary.** The
README's "Build from source" is accurate about the four user-space components and
silent about the kernel extension that is the core of the driver.

### Consequence

The root-port gate at `kexts/NVRM/NVRM.cpp:746` remains a precise, well-specified
three-line patch — and it **cannot be built by anyone outside the project today**.
The only actionable route is upstream: report the gate, and separately request that
`build-nvrm.sh`, `libnvkernel.a` (or the equivalent) and the Darwin ogkm port be
published, or that the placement tolerate a root-complex parent.

## SMOKE TEST RESULT: the published build recipe is INCOMPLETE

I claimed earlier (correcting an earlier still) that the driver is buildable from
the published instructions. **A smoke test in the guest shows that is wrong**, and
the original "upstream don't really have a valid recipe" was closer to the truth.

What was tested, in the macOS guest, on a shallow clone of the driver at `v1.0.9`
plus NVIDIA `open-gpu-kernel-modules` at tag `610.57.04`:

| check | result |
|---|---|
| toolchain | ✅ Apple clang 17, `xcrun`, SDK, **Kernel.framework KPI headers all present** — kext compilation is possible |
| driver source for the NullMoth parts | ✅ `kexts/` present, plus the shipped `kexts/NVRM/accel/re` headers |
| **ogkm builds for Darwin** | ❌ **`inc/libraries/nvport/debug.h:292: error: "Unsupported target OS"`** and `PORT_BREAKPOINT` undeclared. The tree contains **zero** Darwin references; `utils.mk` branches only for Linux/FreeBSD/SunOS |
| `accel_build.sh` prerequisite | ❌ needs `$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh`, an artifact only a Darwin ogkm build produces |
| **which kexts do the scripts build?** | `accel_build.sh` → **NVAccel.kext**; `build_agdc.sh` → **NVRMAGDC.kext**. **Nothing builds `NVRM.kext` or `NVRMFB.kext`** |

**Neither of the two kexts that contain the BAR code is buildable from the public
repo.** `placeLargeBar1()`, `readBARs()` and `nvrmDiscoverBar1()` all live in
`NVRM.kext` / `NVRMFB.kext`, and there is no script for either — they are produced
by the author's Darwin-ported ogkm build, which is not published. The README points
at `open-gpu-kernel-modules` as if a stock checkout suffices; it does not.

One useful by-product: running `make -C src/nvidia` on macOS **does** create
`_out/Darwin_x86_64/` (the path is `_out/$(uname)_$(uname -m)`), so the directory
machinery works — the port is missing at the source level, not the build level.

### What this means for the patch plan

The root-port gate at `kexts/NVRM/NVRM.cpp:746` is a three-line change, and the
patch specification stands. But **it cannot be built today** without either the
author's ogkm Darwin port or writing one — a large project, not a smoke test.

**Therefore the actionable step is upstream, not local:**

1. Report the root-port gate as the blocker, with the exact line and the proposed
   behaviour for a root-complex (no parent bridge) device. That is Findings 10/11
   territory and now has a precise target.
2. Ask the author to publish the NVRM/NVRMFB build scripts and the ogkm Darwin port,
   or to make `placeLargeBar1()` tolerate a root-complex parent.

## CORRECTION: the driver IS buildable — the recipe exists and the RM is open source

An earlier revision of this document accepted the premise that the driver has no
valid build recipe. **That is wrong**, and it matters, because it removes the
strongest objection to the one fix that would actually help.

* **README.md:128** — *"Requires Xcode 16, Rust (stable), Meson/Ninja, and NVIDIA's
  `open-gpu-kernel-modules` at tag `610.57.04`."*
* **`build/accel_build.sh <src> <out>`** builds the kexts with
  `xcrun clang++ -fapple-kext -mkernel -nostdinc -I"$KHDR" ...` and links them with
  `-Xlinker -kext -lkmodc++ -lkmod -lcc_kext`, against `$HOME/ogkm610` (the NVIDIA
  **open** GPU kernel modules) plus `accel/re` headers that ship in the repo.
* Other components have their own scripts: `build_xlate.sh` (translator),
  `build_plugin.sh` (plugin, `RELEASE=1` strips diagnostics), `build263.sh` (NVK,
  which applies `nvk/nvk-macos.patch` to Mesa `17ca6174`).

### What is opaque, and what is not

Only the **firmware blobs** are closed — `Users/Shared/nvfw/nvidia/610.57.04/`
holds `gsp_ga10x.bin`, `gsp_tu10x.bin`, `ucodes_ga10x.bin`, `ucodes_tu10x.bin`.
They are not where the bug is. The BAR handling lives in open source:

* `kexts/NVRM/NVRM.cpp` — `readBARs()` builds the driver's BAR table
* `kexts/NVRMFB/fb/nvrm-fb.cpp` — `nvrmDiscoverBar1()` picks `fBarLen`

Both are exactly what Finding 10/11 proposes to change.

### Binary hashes across releases (measured)

```
NVRM     1.0.0: 16615320 B  dfca5501ecd8e892   ┐ byte-identical
NVRM     1.0.1: 16615320 B  dfca5501ecd8e892   ┘
NVRM     1.0.6: 16750224 B  7eff167632642cab      only +0.8%
NVRMFB   1.0.1 == 1.0.6     144424 B  identical
NVRMAGDC 1.0.1 == 1.0.6      50872 B  identical
NVAccel  1.0.1  697224 B  ->  1.0.6  231560 B     large change
```

So `NVRMFB`/`NVRMAGDC` have not moved between 1.0.1 and 1.0.6, `NVRM` changed by
under 1%, and only `NVAccel` was substantially rebuilt. A patch to `readBARs()` or
`nvrmDiscoverBar1()` would be a small, isolated change to a tree that is already
known to build.

### What this means for the plan

The **4 GiB BAR + driver fix = 2 GiB budget (10x)** route is feasible in principle,
not blocked. It needs, in the guest: Xcode 16, NVIDIA's `open-gpu-kernel-modules` at
tag `610.57.04`, the repo's headers, and a rebuild of the affected kext plus the
auxiliary kernel collection. That is a real project — but it is a *build*, not a
reverse-engineering exercise, which is a very different thing.

## Answering "so it's the driver's job now, and macOS doesn't matter?"

**Half right.** The fix must be driver-side — macOS cannot be patched. But macOS
still *constrains what the driver is able to do*, in three ways that are now all
measured and all unchangeable:

1. **macOS enumerates only bus-0 devices here.** A device behind a root port is
   invisible (IRQ 0, no BARs, zero `10de` nodes in `ioreg`). Re-tested after
   `hotplug='off'` was applied to all five root ports: **still zero `10de` nodes.**
   So there is no root-port parent, and `placeLargeBar1()` can *never* succeed in
   this VM.
2. **macOS corrupts any BAR address above 4 GiB** — it writes a low 32-bit value
   into the high dword.
3. **macOS publishes no `IODeviceMemory` descriptor above 4G**, so the driver's
   `readBARs()` falls back to BAR3 even when the address is fine.

So the driver's job is precisely: **work with what macOS can actually provide** — a
BAR at or below 4 GiB, at a sane address, with or without a descriptor.

### The concrete target

| step | value | status |
|---|---|---|
| host BAR1 | **4 GiB** | macOS places it at `0x1000000000` — sane (measured) |
| driver reads size from | **Resizable BAR capability** | reads correctly at every size already |
| driver reads address from | **BAR registers** (`configRead32(0x10 + 4*bar)`) when no descriptor matches | to implement |
| resulting `fBarLen` | 4 GiB | `fBarLen >= 4 GiB` gate passes |
| resulting budget | **2 GiB** | 10x the current 192 MB |

Note what this does *not* need: `placeLargeBar1()`, a root port, a large BAR, or any
change to macOS, QEMU or OpenCore. It is purely the **reading** path — exactly the
two open-source functions in Findings 10/11, in a tree that builds with
`build/accel_build.sh` and NVIDIA's `open-gpu-kernel-modules@610.57.04`.

## Why the driver wants a large BAR — and who is supposed to place it

This resolves an apparent contradiction between the NullMoth installer and the
Dortania guide.

**NullMoth installer (bare metal):** `ResizeGpuBars = 13` (8 GB physical BAR) and
`ResizeAppleGpuBars = -1` (macOS sees it).

**Dortania (general Hackintosh):** *"When enabling Above4G, Resizable BAR Support may
become available. Please ensure that Booter -> Quirks -> ResizeAppleGpuBars is set
to `0`"* — i.e. hide the BAR from macOS.

These conflict only if you assume macOS must place the BAR. **It does not.** The
author's own comment says so:

> *"13 = 8 GB: the full BAR of an 8 GB card, measured 10-07 on the RTX 5060 (**NVRM
> moves BAR1 out of the console**, display armed)"*

**The driver places the large BAR itself** — `placeLargeBar1()` moves BAR1 into the
firmware's PCI window and arms the display. macOS is only required not to interfere.
Dortania's advice applies to ordinary Hackintoshes whose native drivers never touch
BAR placement; it would break this driver's budget.

### Why that fails in our VM

From the serial log, when the driver attempted it here:

```
NVRM-xnu: bar1: parent root port not found
```

`placeLargeBar1()` **requires a PCIe root-port parent**. Our GPU sits on bus 0 by
necessity, because macOS refuses to enumerate a device behind a root port in this
VM (measured early on: IRQ 0, every BAR "not mapped", invisible to macOS entirely).

| | bare metal | our VM |
|---|---|---|
| who places the large BAR | **the driver** | macOS, because the driver cannot |
| prerequisite | root-port parent | none available |
| outcome | large BAR, large budget | macOS corrupts it, or 192 MB |

**So the deficiency is not that macOS is bad at placing large BARs — it is that we
removed the driver's ability to do it.** The GPU had to move to bus 0 to be visible
at all, and that is exactly what breaks `placeLargeBar1()`.

### The test this implies (not yet run)

The reason a root-port device was invisible was **ACPI hotplug enumeration**
(`IOPCIHPType = 33`, measured). `hotplug='off'` is now applied to all five root
ports and is **kept**. That combination — *root-port hotplug disabled* **and** *the
GPU behind a root port* — has never been tested together, because the hotplug change
came later. If macOS now enumerates a device behind a root port, then
`placeLargeBar1()` gets the parent it needs, the **driver** places the large BAR, and
the budget problem disappears at its root rather than being worked around.

Worth trying before any driver patching: move the GPU to a root port with
`hotplug='off'` in place, and check the serial log for `bar1: PLACED` instead of
`parent root port not found`.

## FINAL SUMMARY: what is wrong, and what could actually fix it

### Address study: host vs Linux guest vs macOS guest

The same physical card, the same 256 MB baseline unless noted:

| where | BAR1 address | how it got there |
|---|---|---|
| **HOST** (the real card) | `0x6000000000` (384 GiB) | host kernel/BIOS assignment |
| **Linux guest** | `0x1000000000` (64 GiB) | Linux re-assigned resources itself |
| **Windows guest** | `0xe000000000` (896 GiB) | kept the firmware's assignment |
| **macOS guest, 256 MB** | `0x90000000` (2.25 GiB, **below 4G**) | macOS's own allocator — works |
| **macOS guest, 8 GiB** | `0x8408400000000000` | macOS's own allocator — **garbage** |

Host regions for reference: BAR0 `0x90000000` (64 MB), BAR1 `0x6000000000` (256 MB),
BAR3 `0x6010000000` (32 MB).

### What this establishes

1. **The guest's BAR address is guest-local.** The host has the card at
   `0x6000000000`, and *no* guest uses that address — Linux picked 64 GiB, Windows
   896 GiB, macOS 2.25 GiB. vfio translates guest-physical to host-physical through
   the IOMMU, so the host's placement puts **no constraint** on the guest.
2. **There is no "correct" answer to compute.** Three operating systems chose three
   different addresses and all three are valid. So macOS is not failing to *match*
   something — it is failing to compute *any* consistent value.
3. **The garbage value is a low-region address in the wrong half.** `0x84084000`
   lies inside the guest's **low** MMIO region (BAR0 is at `0x80000000`, the audio
   function at `0x84a84000`). macOS's allocator appears to have picked an address
   from its 32-bit region and written it into the **high dword** of the 64-bit BAR
   slot. That is a region-mix-up, not a range or size problem.
4. **At 256 MB macOS itself chooses to place the BAR below 4G** (`0x90000000`),
   whereas Windows and Linux place theirs above. So macOS is comfortable with the
   low window — which is consistent with it reaching for a low address when the
   large BAR confuses it.

### Consequence

Nothing on the host needs to change, and nothing on the host *can* fix this: the
address macOS produces is its own invention. The one lever that remains is the
driver accepting a BAR at a size macOS *can* place — which is the 4 GiB case, where
macOS produces the perfectly sane `0x1000000000`.

## What is wrong (all measured, not inferred)

**macOS's PCI resource allocator corrupts the GPU's large BAR address.** It writes a
**low 32-bit MMIO value (`0x84084000` — BAR0's neighbourhood) into the HIGH dword**
of the 64-bit BAR, producing the non-canonical `0x8408400000000000`. QEMU then dies
trying to map it. It is a 64/32-bit mix-up, not a range or capacity problem.

**Every other component has been measured doing the right thing:**

| component | measurement | verdict |
|---|---|---|
| firmware (OVMF) | assigns the 8 GiB BAR at `0xe000000000` with **no OS running** — the same address Windows picks | ✅ correct |
| QEMU + vfio | map an 8 GiB BAR fine — Linux and Windows both boot | ✅ correct |
| OpenCore | runs indefinitely at its own picker with the 8 GiB BAR, no crash | ✅ clear |
| guest address space | 40 physical bits = 1 TiB; 896 GiB fits comfortably | ✅ sufficient |
| platform/SMBIOS | `iMac19,1` and `MacPro7,1` + Cascade Lake (a real Xeon Mac) | ❌ both fail identically |

**Config levers tried and failed**, each verified: `ResizeGpuBars` `-1` and `13`,
`DevirtualiseMmio = true`, `-cpu ...,phys-bits=40`, `q35-pcihost.pci-hole64-size=256GiB`,
`x-no-mmap=on`, all `Kernel -> Add` kexts disabled.

**Consequence for the driver:**

* **>= 8 GiB**: the address is garbage → unusable, and not fixable from the guest
* **4 GiB**: the address is **sane** (`0x1000000000`), but macOS publishes **no
  `IODeviceMemory` descriptor** above 4G, so `readBARs()` falls back to BAR3 and
  `go(2) failed`

### What could actually fix it

**1. The driver-side fix at 4 GiB — the only reachable win.**

Set the host BAR to **4 GiB** (macOS assigns it at a sane address, proven), then fix
the driver's `readBARs()` / `nvrmDiscoverBar1()` (Findings 10 and 11) to:

* read the BAR **size** from the Resizable BAR capability — which reads correctly at
  *every* size (our own log shows `capability @0x134 says BAR1 = 4096 MB`), and
* probe the BAR registers with `configRead32(0x10 + 4*bar)` when no descriptor matches

`fBarLen` then resolves to 4 GiB, `fBarLen >= 4 GiB` holds, and **the grant budget
becomes `fBarLen / 2` = 2 GiB instead of 192 MB** — a 10x improvement, reachable
without touching macOS, QEMU or OpenCore.

**2. macOS-side patching** — infeasible (boot.efi/XNU are Apple's).

**3. QEMU-side** — nothing is broken to fix. The only lever is *what macOS is shown*
(e.g. `ResizeAppleGpuBars`), and that is exactly what the driver forbids: it needs
macOS to expose `fBarLen >= 4 GiB`. The AMD community's workaround (hide the BAR
from macOS) and the NullMoth driver's requirement are **mutually exclusive**.

**So: virtualised hardware is not the bug here.** The firmware presents the card
correctly and two other operating systems accept it. macOS alone mis-places it, and
the one place that can be changed is the driver's fallback for a missing descriptor.

## The firmware's assignment is PERFECT — macOS destroys it

Measured with OpenCore stopped at its own picker (so **no OS runs at all**, only
OVMF + OpenCore) and an 8 GiB host BAR:

```
BAR1: 64 bit prefetchable memory at 0xe000000000 [0xe1ffffffff]   <- 8 GiB, sane, aligned
BAR3: 64 bit prefetchable memory at 0xe2a0000000 [0xe2a1ffffff]
```

**The firmware assigns exactly what Windows chooses** (`0xe000000000`). There is
nothing wrong with the firmware, QEMU, vfio or OpenCore. macOS is handed a correct
assignment and **replaces it with `0x84084000 << 32`**.

### What the garbage value actually is

`0x84084000` is a **low MMIO address** — BAR0 is at `0x80000000` and the audio
function at `0x84a84000`. So macOS writes a **low 32-bit address into the high dword
of the 64-bit BAR**: a 64/32-bit mix-up in its PCI resource allocator, not a range
or capacity problem.

### The address-width hypothesis, tested and DISPROVED

The natural theory was that macOS is handed an address it cannot represent
(`0xe000000000` = 896 GiB needs 40 bits, and `-cpu Skylake-Client` is often a 39-bit
part). Measured on the guest:

```
physical address bits : 40          -> 1 TiB of address space
virtual  address bits : 48
```

**896 GiB fits comfortably inside 40 bits.** `phys-bits=40` was therefore a no-op
(the guest already reported 40), and the theory is dead.

### So: is it worth touching the QEMU stack?

**Not for the BAR assignment** — that is already correct and measured. The only
remaining place macOS could be getting confused is the **ACPI `_CRS` MMIO windows**
it uses when re-placing devices, which OVMF generates and QEMU's runtime knobs do
not control (OVMF's 64-bit window is a build-time PCD, which is why
`pci-hole64-size=256GiB` did nothing). Changing those means an ACPI override or a
rebuilt OVMF — a much deeper project than anything tried so far, and one with no
evidence yet that it would help.

**Bottom line: the bug is inside macOS's PCI resource allocator.** Every component
we can configure has been measured doing the right thing. 256 MB with the 192 MB
budget remains the ceiling, and the driver-side fix (Findings 10/11) remains the
only route that could change it.

## CORRECTED AGAIN: it is macOS's boot.efi, not OpenCore

The picker test settles it. With an **8 GiB host BAR**, OpenCore started and was
left sitting at its own boot picker (`Misc -> Boot -> Timeout = 0`, `ShowPicker`),
so **boot.efi never ran**:

```
state after 35 s: running     RESULT: no crash
```

**OpenCore is clear.** It can run indefinitely with an 8 GiB BAR. The garbage
address is written by **macOS's own boot.efi/XNU when it starts**, which also
finally explains the AMD evidence: macOS's PCI/virtual-memory handling cannot cope
with a large BAR, which is exactly why that community hides the BAR from macOS
instead of using it.

### Everything tried against it, with verification status

| attempt | verified how | result |
|---|---|---|
| Linux twin VM, same hardware, 8 GiB | full boot | ✅ boots, BAR at `0x1000000000` |
| Windows VM, same GPU, 8 GiB | full boot | ✅ boots, BAR at `0xe000000000` |
| OpenCore stopped at its picker, 8 GiB | 35 s, no crash | ✅ **OpenCore is clear** |
| **`DevirtualiseMmio = true`**, 8 GiB | BAR confirmed 8192 MB, config read back **inside** the mount | ❌ still crashes |
| all `Kernel -> Add` kexts disabled | config verified | ❌ |
| `ResizeGpuBars` `-1` and `13` | config verified | ❌ |
| `-cpu ...,phys-bits=40` | config verified | ❌ |
| `q35-pcihost.pci-hole64-size=256GiB` | config verified | ❌ |

`DevirtualiseMmio` was the most promising candidate — its own docstring says it
exists "to reduce the amount of virtual memory required by **boot.efi**", and an
8 GiB MMIO region is exactly that burden. It does not help.

### Conclusion: not reachable by configuration, and not by patching OpenCore

The failure is inside macOS. Patching OpenCore would not help, because OpenCore is
already proven clear. **256 MB with the 192 MB grant budget is the ceiling here.**

The one remaining theoretical route is the AMD one — hide the BAR from macOS with
`ResizeAppleGpuBars` — but that is precisely what the NullMoth driver forbids: its
budget needs macOS to expose `fBarLen >= 4 GiB`, so shrinking the BAR for macOS
removes the very thing the driver wants. The two requirements are mutually
exclusive on this platform. **The driver-side fix (Findings 10/11: read the size
from the ReBAR capability, probe the BAR registers when no descriptor matches) is
the only path that could ever change this.**

### OpenCore build workflow (set up, ready to use)

`/home/tianyixia/ocbuild/OpenCorePkg` is a shallow clone of master (v1.0.8).
`iasl`, `python3`, `gcc`, `make` and `git` are present; `nasm` comes from nix:

```
cd /home/tianyixia/ocbuild/OpenCorePkg
nix shell nixpkgs#nasm -c bash build_oc.tool
```

Note `-c ./build_oc.tool` fails ("unable to execute") — invoke it through `bash`.
Useful targets if this is ever resumed: `Library/OcAfterBootCompatLib/
ServiceOverrides.c` (`ProtectMemoryRegions` at ~line 199 retypes regions;
`DevirtualiseMmio` follows at ~line 245; the `appleLoadedImage` hook at ~line 1251
is where macOS's `GetMemoryMap` is overridden) and `CustomSlide.c`.

## OpenCore patch project — bisect results and handover

### First, what the small BAR actually costs (do not misread this)

**The driver WORKS at 256 MB.** It arms, the display comes up, Metal enumerates the
5080. What the small BAR costs is the **VRAM grant budget (192 MB)**, not function.
So patching OpenCore is what buys a 4 GiB budget, not what makes the driver run.

### Bisect: the trigger is inside OpenCore's own EFI code

At an 8 GiB host BAR, every one of these still produced the non-canonical address
`0x8408400000000000` and the QEMU crash:

| change | result |
|---|---|
| **every `Kernel -> Add` kext disabled** | ❌ still crashes → **not a kext** |
| `SSDT-DTGP.aml` disabled | ❌ still crashes (and it was not in `ACPI -> Add` anyway) |
| `ResizeGpuBars = -1`, `13` | ❌ not the ReBAR write path |
| `DevirtualiseMmio = true` | ❌ |
| `-cpu ...,phys-bits=40` | ❌ |
| `q35-pcihost.pci-hole64-size=256GiB` | ❌ |

Active `ACPI -> Add` is only `SSDT-EC.aml` and `SSDT-USBX.aml`; the other `SSDT-*.aml`
files sit in the directory unused. `EFI/OC/Drivers/` holds `OpenPartitionDxe.efi`,
`OpenRuntime.efi`, `ResetNvramEntry.efi`, `ToggleSipEntry.efi`.

### Confirmed: the ESP being edited is the live one

`OpenCore.qcow2` p1 holds `EFI/OC` and its `config.plist` mtime tracks our edits;
`macos.img` p1 is FAT but carries **no** `EFI/OC`. So config edits do take effect —
the earlier confusion came from `ACPI -> Add` listing fewer tables than the
directory contains.

### Recommended next steps, cheapest first

1. **Try a different OpenCore version** — build the same config on 0.9.x and 1.0.x.
   If an older build does not crash, this is a regression and the fix is targeted.
2. **Drop `OpenRuntime.efi`** and see whether the crash survives. macOS will not boot
   without it, but the *crash* is the signal we need, and it is the most likely owner
   of MMIO/memory-map handling.
3. **Patch and build OpenCore** (OpenCorePkg + EDK2). Instrument the MMIO/PCI paths
   in `OcRuntimeLib`/`OpenRuntime` to log every BAR address write, then find where
   the high dword gets the low 32-bit value. Note `Library/OcDeviceMiscLib/
   SetResizableBar.c` is the ReBAR *write* path and is already exonerated by the
   `-1` test — the fault is elsewhere in the MMIO/memory-map handling.

The twin VM XMLs for cheap A/B testing are in `/home/tianyixia/linuxvm/`
(`linux-bar-test.xml`, `macos-nooc.xml`), and a known-good OpenCore config is at
`/home/tianyixia/linuxvm/oc-config.working.bak`.

### Historical note: Pascal and the High Sierra era

**Pascal has no Resizable BAR at all** — GTX 10-series BARs are fixed at 256 MB
(the AMD OS X / Hackintosh threads from that era show GTX 1080s reporting `256mb`).
ReBAR only arrived with GTX 16/RTX 20 (via vBIOS) and RTX 30, and with AMD RX 6000.
So High Sierra passthrough never faced this problem and had no workaround — there
was no large BAR to handle. The AMD "shrink the BAR for macOS" recipe is a
*post*-ReBAR solution to a situation Pascal never entered.

## Definitive BAR conclusion (host-resize-only, no OpenCore code patch)

**You cannot get a usable BAR larger than 256 MB on this setup. 192 MB is the
ceiling.** Measured, each with the host setting the size and OpenCore NOT
resizing (`ResizeGpuBars = -1`):

| host BAR1 | QEMU | macOS | driver |
|---|---|---|---|
| **256 MB** | boots | assigns below 4G | **works — 192 MB budget** |
| 2 GiB | boots | assigns above 4G | ✗ BAR1 not in `bars`, `go(2) failed` |
| 4 GiB | boots | assigns above 4G | ✗ no descriptor → `bars[FB]` = BAR3 → `go(2) failed` |
| 8 GiB | **crash** | — | — |
| 16 GiB | **crash** | — | — |

### CORRECTION: it is NOT a QEMU bug — it is the macOS-side PCI placement

The decisive experiment: boot **`win11-stealthy-dgpu` with the same 8 GiB host
BAR**. Windows works perfectly:

```
win VM state: running     crashed? 0
BAR1: 64 bit prefetchable memory at 0xe000000000 [0xe1ffffffff]   <- 8 GiB, sane
BAR3: 64 bit prefetchable memory at 0xe200000000 [0xe201ffffff]
```

**QEMU and vfio map an 8 GiB BAR cleanly.** The macOS guest is the one producing
`0x8408400000000000`, and QEMU only crashes because it then tries to map that
garbage. The difference between the guests:

* **Windows re-assigns PCI resources itself** and placed the BAR at 896 GiB —
  outside QEMU's declared 32 GiB hole entirely, and perfectly valid.
* **macOS does not; it inherits/derives a 32-bit-limited placement**, taking a low
  MMIO value (`0x84084000`, from BAR0's neighbourhood) and writing it into the high
  dword of the 64-bit BAR.

So the blocker is in the guest-visible PCI resource map, not in vfio.

### Approaches tried for it, all failed

| attempt | result |
|---|---|
| `ResizeGpuBars = -1` (guest must not resize) | ❌ still crashes — OpenCore was never the cause |
| `x-no-mmap=on` | ❌ crash avoided but the address is **byte-identical**; it is a DEBUG option ("Allows to trace MMIO accesses") that traps all MMIO in userspace |
| `DevirtualiseMmio = true` at 4 GiB | ❌ no difference |
| `-global q35-pcihost.pci-hole64-size=274877906944` (256 GiB) | ❌ identical garbage address — OVMF's 64-bit window is a **build-time PCD**, not this |

### Why >= 8 GiB crashes — the mechanism (kept for the record)

```
kvm_set_user_memory_region: failed, slot=10,
  start=0x8408400000000000, size=0x200000000 (8 GiB)
```

**The guest BAR address is the problem: `0x84084000 << 32`** — a 32-bit MMIO value
in the high dword of a 64-bit BAR. `x-no-mmap=on` stops the crash but the address
stays identical (`BAR1: 64 bit prefetchable ... at 0x8408400000000000`), so it only
hides the symptom — and it is a **debug option** ("Disable MMAP for device. Allows
to trace MMIO accesses (DEBUG)"), which traps every MMIO access in userspace.
**Not a solution, and not worth its cost.**

### Why 4 GiB is not usable either

macOS assigns a 4 GiB BAR **above 4G** (at `0x1000000000`) and then publishes **no
`IODeviceMemory` descriptor** for it. The driver builds its entire BAR table from
those descriptors (`readBARs`, `nvrmDiscoverBar1`), so `bars[FB]` silently falls
back to BAR3 and RM init fails. A >= 4 GiB BAR can never be placed below 4G (the
below-4G window is 2 GiB), so this is unavoidable at that size.

`DevirtualiseMmio = true` (the OpenCore quirk for >4G MMIO) was tested at 4 GiB and
made no difference.

### What the author's own installer does on bare metal — and why it does not apply

`app/Resources/nullmoth-setup.sh` sets, for an installed system:

```
ResizeGpuBars      = 13   # 8 GB BAR, "the driver was tested with the card's full 8 GB BAR"
ResizeAppleGpuBars = -1   # "macOS sees the full BAR"
```

So **macOS handles a full 8 GB BAR fine on real hardware** — the author ships
exactly that. The blocker is our VM's PCI layer, not macOS and not the driver.
Two things rule OpenCore out as the fix:

* OpenCore's `SetResizableBar.c` only **writes the PCI config space** — it resizes.
  Its docs are explicit: *"**Reduce** GPU PCI BAR sizes for compatibility with
  macOS... Example 3: Setting ResizeAppleGpuBars to 16 GB will make **no changes**."*
  **There is no "report a size without resizing" mode**, which was the plan.
* On a passed-through card OpenCore's resize does not take effect anyway: with
  `ResizeGpuBars = 13` the driver still reported `bar1@0x14:0x90000000+0x10000000`
  (256 MB).

### Where a real fix would have to go

1. **Guest-firmware / ACPI side** — make the 64-bit MMIO window the guest sees big
   enough, or make macOS re-assign resources. Concretely, the leads are: compare
   the host bridge `_CRS` macOS sees against what Windows sees; and rebuild OVMF
   with a larger `PcdPciMmio64Size` (build-time, which is why the QEMU
   `pci-hole64-size` override did nothing). A small Linux VM with passthrough is
   a cheap third data point: Linux re-assigns resources like Windows, so it should
   also succeed, confirming this is macOS-specific.
2. **Driver-side** — Finding 10: read the BAR size from the Resizable BAR
   capability (which reads correctly at *every* size) and probe the BAR registers
   via `configRead32` when no descriptor matches.

**Until one of those lands, keep BAR1 at 256 MB and keep the `nvrm610.conf` fix.**
The conf workaround cannot be lifted: it compensates for the 192 MB budget, and a
larger BAR is not reachable.

## Still open (honest list)

1. **The ~0.5 s drag-start stall is not fixed.** First-use shader compilation is
   the plausible cause — `shaderbench` measures **median 17.7 ms, p90 32 ms, max
   203 ms** per distinct shader, so a drag needing several new pipeline variants
   could total ~0.5 s, and the caches being warm explains why the *repeat* drag is
   smooth. But it is not proven, because the synthetic load cannot reproduce the
   stall (see the `dragload` limitation above). **Next step: a real drag while
   watching the shader caches and the park/refusal counters.** If it is
   compilation, nothing here can fix it — the caches are already warm and the
   translator is inherent to the driver.
2. **The park/refusal thrash is gone in this configuration** (`parks +0`,
   `refusals +0` in the final benchmark, against 3779/474 in the pre-fix boot) but
   the underlying cause is untouched: allocations still land on the console/scanout
   range and are parked and retried. It is quiet now, not fixed.
3. **Mode changes remain a crash risk** and there is no way to get a lower refresh
   at native resolution.

## Known limitations

* **Heavy GPU consumers regress the compositor.** The compositor's surface budget
  is 192 MB and normally sits ~93% full, so launching Steam (a GPU-composited
  Chromium UI) leaves too little headroom and dragging drops back toward the teens.
  Closing Steam recovers. See
  [Performance](#performance-the-compositor-is-squeezed-into-a-192-mb-window) —
  this is the 256 MB BAR's ceiling, and the only real fix is upstream.
* **Only 165 Hz is offered at native resolution**, because NVRMFB publishes no
  lower refresh at the native timing. Lower resolutions do offer 60 Hz. See
  [Display modes](#display-modes-165-hz-at-native-resolution-only).
* **Changing resolution wedges the display** (blank background, live cursor,
  WindowServer goes idle but does not crash). Recovery is a WindowServer restart,
  which logs you out. See [Changing display
  resolution](#changing-display-resolution-wedges-the-display).
* **The dynamic wallpaper works** (it renders, GPU-composited), which means the
  static-wallpaper workaround below is **no longer needed**. Kept for the record
  because it is the right fix if Metal is ever unavailable — a *dynamic* wallpaper
  needs Metal, and without it the desktop falls back to plain white, which is the
  pre-fix symptom we originally chased.

  ```sh
  cp "/System/Library/Desktop Pictures/.wallpapers/Sequoia Sunrise/Sequoia Sunrise.heic" \
     "$HOME/Pictures/Sequoia Still.heic"
  sudo launchctl asuser "$(id -u)" osascript -e \
    'tell application "System Events" to set picture of every desktop to "'"$HOME"'/Pictures/Sequoia Still.heic"'
  ```

  Copy the file **out of** `/System/Library/Desktop Pictures/` first: pointing the
  desktop at a file that *belongs to* a dynamic provider re-resolves to that
  provider and stays dynamic. `launchctl asuser` is required, or the AppleScript
  runs in the SSH session instead of the GUI session.
* **Mobile Blackwell is outside the driver's tested set.** The README says it was
  developed on an RTX 5060 (`2d05`); this is `10de:2c59`, RTX 5080 Max-Q. It works
  here, but that is one more data point, not a guarantee.
* **The driver wants the card powered on.** If you power the dGPU down between
  uses, bring it up before starting the domain.

---

## Recovery

Have these ready **before** you install, not after.

* **`-nvoff`** — NVRM honours it and leaves the card alone. Add to boot-args to
  disarm the driver without uninstalling.
* **`install.sh` is safe by construction** — it test-builds the kernel collection
  before writing anything and writes a numbered backup to `/Library/NullMoth/backup-*`.
  `uninstall.sh <dir>` is the way back, but that needs a bootable system, so keep
  SSH working.
* **The 1401 app adds a picker entry** — *"NullMoth: remove the NVIDIA driver at
  the next start"* (`Misc → Tools`, `NullMothSafe.efi`) — which is the cleanest
  escape if the display or the boot misbehaves.
* **Keep SSH reachable.** With `<video>=none` there is no console to fall back on,
  so SSH is your only way in.

---

## Appendix A — avenues that do NOT work (don't spend time on them)

* **Moving the GPU to a PCIe root port.** Retested with `pcie-root-port.hotplug=off`
  **and** `pcie-root-port.x-do-not-expose-native-hotplug-cap=on`: still invisible.
  See section 2.
* **A conventional PCI bridge** (`dmi-to-pci-bridge` / `i82801b11-bridge`). macOS
  **does** enumerate the GPU behind this (`pcidebug 1:1:0`) — but conventional PCI
  has only a 256-byte config space, so the Resizable BAR capability at extended
  offset `0x134` is invisible and the driver bails at `"bar1: no Resizable BAR
  capability"`. Also note on a PCI bus slot 0 is the bridge, so devices need
  `slot >= 1` (libvirt: *"slot must be >= 1"*). Net: the two requirements are
  mutually exclusive in QEMU — a PCIe port gives extended config but macOS won't
  enumerate it; a conventional bridge is enumerated but gives no extended config.
* **`ResizeAppleGpuBars`** (`-1`, `8`, `0`) — no effect whatsoever on a
  passed-through GPU.
* **Patching the driver.** Blocked: the repo publishes **no build path for
  `NVRM.kext`/`NVRMFB.kext`**. `build/accel_build.sh` builds only `NVAccel`;
  `kexts/NVRM/rmcc.py` references a `build-nvrm.sh` that is absent, and needs
  `$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh` plus `libnvkernel.a`
  (a Darwin build of NVIDIA's RM) which are not published. Moot now — no patch
  was needed.
* **`x-no-mmap=on` / `x-no-kvm-intx`** hostdev workarounds — these were
  compensating for the oversized BAR and are unnecessary once BAR1 is 256 MB.
* A **`USBPorts.kext`** port map for the USB problem — see section 4.

## Appendix B — capturing the driver's log

The driver logs with **`kprintf`**, which never reaches the unified log — and
`dmesg` shows 0 NVRM lines, because `debug=0x8` routes it to the serial port
instead. This is how to actually read it:

1. Add `debug=0x8 serial=1` to the guest boot-args (and to `NVRAM → Delete`).
2. Point QEMU's serial at a file on the host:

   ```xml
   <serial type='file'>
     <source path='/tmp/macos-serial.log' append='off'/>
     <target type='isa-serial' port='0'><model name='isa-serial'/></target>
   </serial>
   ```

3. `tr -d '\0' < /tmp/macos-serial.log | strings > /tmp/serial-clean.txt`

This is what produced every driver quote in this document. Restore
`<serial type='pty'>` afterwards if you want `virsh console` back.

## Appendix C — why 256 MB, and how it was found

The measurement table (macOS 15.8.1 + NullMoth 1.0.1, RTX 5080 Max-Q):

| host BAR1 | macOS assigns BAR1? | driver result |
|---|---|---|
| 256 MB | **yes** — `bar1@0x14:0x90000000+0x10000000` | **works**: `rm_init_adapter -> OK`, `IOFramebuffer` 0 → 5 |
| 512 MB / 1 GiB / 2 GiB | no | `bars[FB]` = BAR3 → `kbusVerifyBar2` asserts |
| 4 GiB | no | same |
| 8 GiB / 16 GiB | no | same, plus QEMU/KVM cannot even place the BAR (see below) |

At 16 GiB the problem starts earlier: QEMU/OVMF places the BAR at a
**non-canonical** address and KVM rejects it outright.

```
kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
  start=0x8508000000000000, size=0x400000000: Invalid argument
vfio_container_dma_map(...) = -22 (Invalid argument)
```

`0x8508000000000000` is outside both the userspace (`< 0x800000000000`) and kernel
(`>= 0xffff800000000000`) ranges, and equals `0x85080000 << 32` — a 32-bit MMIO
base written into the high dword of a 64-bit BAR. Not an intended address.
Shrinking on the host fixes the transport; 256 MB additionally satisfies macOS.

The chronological debugging log, including the wrong turns, is in
[DEBUG-HISTORY.md](DEBUG-HISTORY.md). **Do not follow it** — it is kept only
because the *methods* are reusable.
