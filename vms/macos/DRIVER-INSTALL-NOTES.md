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

## TL;DR — four things must be right

If you get these four right, the driver works. Each has a distinctive failure
signature, so you can tell which one you've got wrong.

| # | Requirement | If wrong |
|---|---|---|
| 1 | **BAR1 must be 256 MB** (set on the *host*) | driver loads but `rm_init_adapter` fails; no display |
| 2 | **GPU on guest bus `0x00`** — not behind a PCIe root port | macOS never sees the card at all |
| 3 | **`<video>` = `none`** | the emulated GPU competes with NVRMFB for display index 0 |
| 4 | **USB hostdevs on an XHCI controller** | passed-through keyboard/mouse never appear in macOS |

Three **runtime gates** then bring the display and Metal up (they are lost on
every reboot — see [Bring-up](#bring-up-three-runtime-gates)).

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

## Bring-up: three runtime gates

Getting the driver loaded is not enough — macOS still shows no display. Three
steps fix that, and **all three are runtime-only** (they are gone on reboot).
They must run **after** the driver is up.

| gate | command | what it does |
|---|---|---|
| 1 | `sudo sysctl -w debug.nvrmfb_agdc=1` | activates `NVRMAGDC`, the display-policy shim, which maps the framebuffer. **Necessary but not sufficient** — held `IODisplay` at 0 for a full 60 s on its own. |
| 2 | `sudo launchctl kickstart -k system/com.apple.WindowServer` | **this is the step that produces the display.** WindowServer re-enumerates and `IODisplay` goes 0 → 1 within ~5 s. |
| 3 | `sudo sysctl -w debug.nvaccelfb=1` | restores `MetalPluginName`, so **new** processes get a Metal device. |

**Timing matters.** The driver only reaches `"up"` about **100 s after NVRM
arms** (`auto-go: go(2) in 100000 ms`, because `placeLargeBar1()` returns false
at a 256 MB BAR1). Applying the gates at boot, before pass 2 completes, silently
does nothing — the driver logs `AGDC: no PCI device or no framebuffer yet (pci 0
fb 0)`. Wait for the driver, not for boot:

```sh
until ioreg -l -w0 | grep -q '"nvrm-autogo" = "up"'; do sleep 5; done
```

Gate 3 has a caveat the driver states itself: only **new** processes see the Metal
device; already-running ones do not. Re-run your test in a fresh process.

**Not yet tested:** whether gate 1 is a *prerequisite* for gate 2. It was active
when gate 2 succeeded, but gate 2 with AGDC left off was never tried — so if you
want the minimum, that experiment is owed.

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

## Why the desktop is not on Metal — and the allow-list order bug

**The desktop IS supposed to run on Metal.** This is not a design decision on the
driver's part — the README is explicit: *"your NVIDIA card drives the desktop"*,
*"NVAccel the accelerator WindowServer composites through"*, and *"the AMFI args
let WindowServer load the driver bundle"*. It fails here for a specific,
identifiable reason.

### Root cause: the 40 s boot-hold loses a race against the 100 s auto-go

NVRM deliberately holds the IORegistry busy so WindowServer's `IOKitWaitQuiet`
blocks, which is what sequences WindowServer to start *after* the driver is
armed. The hold has a **fixed 40 s cap**, but the schedule it races is **10 s or
100 s** depending on `bar1Placed` (`kexts/NVRM/NVRM.cpp`, ~line 328):

```c
clock_interval_to_deadline(40000, kMillisecondScale, &dl);          // fixed 40 s
setProperty("nvrm-autogo", bar1Placed ? "scheduled +10 s" : "scheduled +100 s");
```

| `bar1Placed` | auto-go | vs 40 s | outcome |
|---|---|---|---|
| true | `+10 s` | 10 < 40 | hold outlives bring-up → WindowServer waits → **Metal desktop** |
| false (ours) | `+100 s` | 100 > 40 | **cap fires first** → WindowServer starts early → no Metal desktop |

Ours is the second row, because macOS assigns only a **256 MB** BAR1 so
`placeLargeBar1()` returns false. The driver's own log states the consequence:

```
auto-go: go(2) in 100000 ms on its own thread (BAR1 not placed); registry held busy until the display is armed (cap 40 s)
boot hold RELEASED by the 40 s cap
```

and `bootHoldCap()` predicts it: *"bring-up not finished, NOT arming"* / *"the
bring-up will not arm with WindowServer up"*.

**So the same BAR limitation that makes the driver run at all is what keeps the
desktop off Metal.** Larger BAR sizes fail outright (`kbusVerifyBar2_GB202` /
`NV_ERR_MEMORY_ERROR`), 256 MB is the only value macOS accepts — and that is
exactly the case the 40 s cap cannot accommodate. There is no configuration of
this VM that satisfies the README's `ResizeGpuBars=13` /
`ResizeAppleGpuBars=-1` requirement.

**Recovery does not work either.** Restarting WindowServer by hand so it picks up
the driver mid-session hands WindowServer a Metal path it cannot sustain, and the
UI freezes — the cursor still moves, because that is NVRMFB's hardware plane, not
WindowServer's. That is the freeze described below.

**The fix belongs upstream** — derive the cap from the schedule, e.g.
`clock_interval_to_deadline(fAutoGoSettleMs + 40000, ...)`. It is not patchable
here: there is still no published build path for `NVRM.kext`. Full write-up in
[UPSTREAM-REPORT.md](UPSTREAM-REPORT.md).

### Consequence, and why the daemon denies WindowServer

`debug.nvaccelfb` is a **global** gate — it decides whether the accelerator
publishes `MetalPluginName` at all. So it is all-or-nothing:

| | desktop | Metal for apps/games |
|---|---|---|
| `nvaccelfb=0` (what we run) | works | **none at all** — `MTLCopyAllDevices() -> 0` |
| `nvaccelfb=1` | freezes on a WindowServer restart | Metal 3 |

Arming is also a **one-way door until a reboot**: `sysctl -w debug.nvaccelfb=0`
provably does nothing (`1 -> 1`); the driver documents this as *"a reboot takes it
away again"*. Arming additionally sets `IOGLBundleName=AppleMetalOpenGLRenderer`
globally, which redirects the GL renderer and which excluding WindowServer from
the Metal plugin does not necessarily prevent.

So the daemon leaves Metal **off** by default, and the `-WindowServer` deny is
what makes its own WindowServer restart safe — without it, that restart is exactly
the freeze above.

### The allow-list order bug (separate, upstream)

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

## Known limitations

* **No Metal at all in this configuration — not for apps either.** The desktop is
  *supposed* to run on Metal (see the section above), but the same 256 MB BAR that
  makes the driver run forces the 100 s auto-go path, which loses the race against
  the fixed 40 s boot-hold, so WindowServer starts before the driver is ready. As a
  result `debug.nvaccelfb` must stay off, and that gate is global:
  `MTLCopyAllDevices() -> 0` and `MTLCreateSystemDefaultDevice() -> nil` for every
  process. **Games, Core ML, MPS and OpenCL therefore get no GPU acceleration** —
  the driver's display path works, its compute path is unreachable. This is a
  consequence of the VM's BAR constraint, not a maturity stage; the fix is
  upstream ([UPSTREAM-REPORT.md](UPSTREAM-REPORT.md)).
* **The dynamic wallpaper cannot render.** macOS 15's stock wallpaper is a
  *video* (`.wallpapers/Sequoia Sunrise/Sequoia Sunrise.mov`), which needs Metal,
  so the desktop is plain white. Use a **static** wallpaper instead:

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
