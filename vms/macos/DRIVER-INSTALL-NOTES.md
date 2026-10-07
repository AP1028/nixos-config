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

macOS's `IOPCIFamily` will **not assign** a Resizable BAR larger than 256 MB. At
1 GiB or 4 GiB it lists BAR1 in the device's `reg` property (so it knows the BAR
exists) but never in `assigned-addresses`, so **no `IODeviceMemory` descriptor is
created**:

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
