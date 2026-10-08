# Working recipe — NullMoth NVIDIA driver in a QEMU/KVM macOS 15 guest

**Status: working.** GPU-composited desktop, Metal 3 for applications, and a **16 GiB
BAR with an 8 GiB VRAM budget** (the starting point for this work was 192 MB).

This supersedes the TL;DR that used to head `DRIVER-INSTALL-NOTES.md`. Several of those
requirements were later disproved — see **Superseded claims** at the end. The long
investigation history stays in `DRIVER-INSTALL-NOTES.md`; this file is the recipe.

---

## The configuration

Four things matter. Together they take the driver from "loads but unusable" to fully
working.

| # | Setting | Where |
|---|---|---|
| 1 | `-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off` | libvirt XML, `<qemu:commandline>` |
| 2 | GPU **behind a PCIe root port** (guest bus `0x01`) | libvirt XML, hostdev address |
| 3 | Host BAR1 = **16 GiB** (`resource1_resize`, bit index 14) | host, before starting the VM |
| 4 | Driver at **shipped defaults** — no conf workaround | guest `/Library/GPUBundles/nvmtl/nvrm610.conf` |

**Setting 1 is the one that unblocks everything.** macOS will not resource a
passed-through device behind a PCIe root port while QEMU advertises ACPI hotplug for
bridges — it sees the card in config space and then assigns it nothing, because the root
ports publish zero-size `ranges`. With that property off, macOS resources the device
normally, the driver's `placeLargeBar1()` finally has the parent bridge it requires, and
it places its own BAR.

The comment in the driver's own tree is what identified this; **OSX-KVM carries the same
line commented out** in `OpenCore-Boot.sh`:

```
# -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
```

---

## Host setup

### 1. Bind the GPU to vfio-pci

```bash
G=/sys/bus/pci/devices/0000:01:00.0
D=/sys/bus/pci/drivers/vfio-pci
echo "" > $G/driver_override            # must be cleared before unbind
echo "0000:01:00.0" > $D/unbind
echo "vfio-pci" > $G/driver_override
echo "0000:01:00.0" > $D/bind
```

Also bind function 1 (the GPU's audio device) if passing it through.

### 2. Set BAR1 to 16 GiB

`resource1_resize` takes the **bit index** of the size in the PCIe Resizable BAR
capability:

| bit | size |
|---|---|
| 8 | 256 MB |
| 11 | 2 GiB |
| 12 | 4 GiB |
| 13 | 8 GiB |
| **14** | **16 GiB** |

```bash
printf "14\n" > $G/resource1_resize
```

Verify it took (this is the step people skip):

```bash
python3 -c "l=open('$G/resource').readlines(); a=int(l[1].split()[0],16); b=int(l[1].split()[1],16); print((b-a+1)/2**30,'GiB')"
```

Do this **while the VM is off**. The size must be applied before the guest boots,
because the guest's driver reads the capability at startup.

### 3. Point the GPU at a PCIe root port, and add the property

In the domain XML, put the hostdev on the first root port's bus (bus `0x01`, not
`0x00`) and add the QEMU argument:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0' multifunction='on'/>
</hostdev>
```

```xml
<qemu:commandline>
  <!-- ... -cpu, isa-applesmc, -smbios ... -->
  <qemu:arg value='-global'/>
  <qemu:arg value='ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off'/>
</qemu:commandline>
```

**Verify it reaches QEMU.** libvirt silently drops attributes it does not understand —
`hotplug='off'` on a `<controller>` is one of them, and cost a lot of time here:

```bash
P=$(pgrep -f "guest=macos" | head -1)
tr '\0' '\n' < /proc/$P/cmdline | grep -c acpi-pci-hotplug-with-bridge-support   # must be >= 1
```

Keep `<video><model type='none'/></video>`, and put USB hostdevs on an XHCI controller.

---

## Guest setup

* **Driver**: `nvidia-macos-driver` release **v1.0.13** (driver 1.0.9). `NVRM` is
  byte-identical to 1.0.6; `NVRMFB` gained a vblank fix.
* **`nvrm610.conf`**: leave at **shipped values**. No workaround is needed once the BAR
  is real — that was the point of the exercise. (See "Superseded claims".)
* **boot-args**: `keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth
  amfi_get_out_of_my_way=0x1 amfi=0x80 debug=0x8 serial=1`.
  `nvrmsettle=15000` is **no longer needed** and should be removed.
* **OpenCore**: `ResizeGpuBars=-1`, `ResizeAppleGpuBars=-1`, `DevirtualiseMmio=False`.

The installer resets `nvrm610.conf` on every install. If you have previously edited it,
re-check after installing.

---

## Verification

```bash
# driver reached pass 2 and claimed the GPU
ioreg -l -w0 | grep '"nvrm-autogo"'                 # -> "up"

# all four kexts loaded
kmutil showloaded | grep -c nullmoth                # -> 4

# a display exists and is being driven
ioreg -rc IODisplay -w0 | grep -c -- "+-o "         # -> 1

# THE NUMBER THAT MATTERS: the VRAM budget
sysctl -n debug.nvrmfb_vram_budget_bytes            # -> 8589934592  (8 GiB)

# the BAR the driver placed for itself
ioreg -l -w0 | grep '"nvrm-bars"'
#   bar1@0x14:0x1000000000+0x400000000          <- 16 GiB
```

The driver's own log (visible on the serial console, or via `dmesg`) should read:

```
bar1: Resizable BAR capability @0x134 says BAR1 = 16384 MB (sizes supported mask 0x4000)
bar1: host bridge 64-bit window 0x1000000000-0x17ffffffff (ACPI _CRS), CPU reaches 40 bits
bar1: placing BAR1 16384 MB @0x1000000000, BAR3 32 MB @0x1400000000 ... PLACED
```

`PLACED` means the driver did the BAR placement itself — the mechanism the author
designed, and the thing that was unreachable before the root-port fix.

### Reference performance

`bench.sh`, 18 s autonomous drag, 8 GiB budget:

```
flips 2438   WindowServer 16.43 s -> 6.74 ms/flip
grants +2   parks +0   refusals +0
compositor flips: 2436 -> 135.3 fps
```

`parks +0` and `refusals +0` are the numbers to watch. Continuous-drag fps varies
(91-140 fps across runs) — **treat parks, refusals and ms/flip as the stable
indicators**, not the fps headline.

---

## Known bugs and limitations

These are real and current. They are driver-side; none is fixed by configuration.

### 1. A display-mode transition wedges the display

Switching a fullscreen app (or any mode change) leaves the panel alternating between the
desktop and the dead app's last frame, or frozen with only the cursor moving. **Guest
reboots do not clear it** — with vfio passthrough the guest driver programs the physical
GPU, and a guest reboot never resets it.

**Recovery** — see the ladder below. Identified mechanism: the scanout binding survives
the mode change, and the driver keeps presenting to a surface that is no longer updated.
The driver's own source comment names the remedy: *"WindowServer composites it only after
a WindowServer restart"*.

**Practical rule: run games windowed/borderless.** That avoids the trigger entirely.

### 2. Park leak — window-switch drag lag

`kexts/NVRM/fb/nvrm-fb.cpp:1261`:

```c
SInt64 before = OSAddAtomic64(want, &gVramMappedBytes) + gVramParkedBytes;
if (before + want > budget) { ...refuse... }
```

`gParkedForever[24]` holds console/scanout-overlapping allocations and **never releases
them**, and their bytes are counted against every later grant. Measured: **8-16 VRAM
refusals per window switch**, climbing, while `mapped` is only 120 MB of an 8 GiB
budget — so parked bytes are consuming nearly the whole budget.

Symptom: continuous dragging is fine, the **first drag after switching windows** delays.

* A **reboot clears it** (in-kernel state), so it returns progressively.
* **Running a game accelerates it** — many surfaces cycled.
* Note `nvaccel_vm_refused` counts "refused by the framebuffer"; the parked figure itself
  is **not exposed as a sysctl** and is inferred from the refusal condition.

### 3. Shader translation is the performance bottleneck

`libnvmtl_translate.dylib` (Metal → SPIR-V, Rust) dominates. Measured during gameplay:
**2338 of ~2500 samples in `nvmtl_translate`** vs 85 in `Render`. Entering a game world
causes a multi-second stall while pipelines compile, then recovers — it is slow, not
broken. Lowering quality presets reduces the number of pipelines.

### 4. Upscalers produce a wrong image

NMS with `MetalFXMode=Spatial` + `AntiAliasing=MetalFXSpatial` + `DLSS=UltraPerformance`
renders a **partially formed image**: the game renders at reduced internal resolution and
expects the upscaler to reconstruct it, and the translation layer does not implement
these. Fix — all off, render native:

| setting | value |
|---|---|
| MetalFX / AntiAliasing | `Off` / `TAA` (or `None`) |
| DLSS (+ frame generation) | `Off` |
| NVIDIA Reflex Low Latency | `Off` |
| Dynamic resolution scaling | lowest factor `1.0` |

### 5. `screencapture` cannot see a game's output

Games present through the driver's **zero-copy direct scanout**, bypassing the
WindowServer composite. So `screencapture` returns only the desktop, even with the game
frontmost and running. Use the game's own screenshot function instead.

---

## Recovery ladder (cheapest first)

| step | effect |
|---|---|
| **1. `sudo killall -9 WindowServer`**, then log in | Re-binds the scanout. ~30 s, logs out. **Verified.** Keeps the VM, the BAR and the conf. |
| **2. Host FLR**: unbind vfio-pci, `echo 1 > .../reset`, rebind, restart VM | **Verified.** Costs a VM restart. |
| 3. Guest reboot | Clears the parked bytes, but **does not** clear a scanout wedge. |

**Does nothing** (all tested): Metal shader cache clear, `killall Dock`, wallpaper change,
display sleep/wake, `debug.nvaccelfb=3`, `debug.nvaccel_iop_async=0`.

If the display wakes but the WindowServer's CPU time sits frozen, that is the wedge, not
a sleep state — go to step 1.

---

## Superseded claims

Earlier revisions of `DRIVER-INSTALL-NOTES.md` asserted these. Each was disproved by
measurement, and the corrections are what made the current configuration possible.

| old claim | now |
|---|---|
| "BAR1 must be 256 MB" | **16 GiB works** — and is the point |
| "GPU must be on guest bus `0x00`" | **behind a root port** (bus `0x01`) is required for `placeLargeBar1()` |
| "no `IODeviceMemory` descriptor above 4G, so 256 MB is a hard ceiling" | resolved: the driver places its own BAR once it has a parent bridge |
| "`nvrm610.conf` at the code defaults" | **shipped values**; no workaround needed |
| "`nvrmsettle=15000` is required" | not needed — remove it |
| "macOS writes a garbage BAR address above 4G" | it could not resource the device; with the root-port fix it never generates one |

The rule that produced every one of these corrections: **verify at the consumer, never at
the writer.** libvirt, OpenCore and the game all silently discard configuration, and a
dropped setting looks identical to a setting that does not work.

---

## Open items for upstream

1. **Scanout binding survives a display-mode transition** — the cause of the wedge and
   the flash; needs a WindowServer restart to re-bind.
2. **Park leak** — `gParkedForever` has no release path, and parked bytes are charged
   against every later grant, so the budget is consumed by allocations nothing uses.
3. **Translation throughput** — pipeline compilation dominates; a persistent cache would
   remove the stall on world load.
4. **Buildability** — `NVRM.kext` cannot be built from public sources: `build/` emits
   only NVAccel/NVRMAGDC/plugin/translator/NVK, the public open-gpu-kernel-modules has no
   Darwin support, and the scripts need unpublished artifacts (`build-nvrm.sh`,
   `libnvkernel.a`, `$NV/_out/Darwin_x86_64/compile_cmds.sh`). Verified three ways.
   `destroyScanoutResource`/`setupScanout` are **headers only** in the public tree, so the
   display bugs cannot be patched from outside either.
