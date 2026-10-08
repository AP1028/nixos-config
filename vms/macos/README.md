# NullMoth NVIDIA driver in a QEMU/KVM macOS guest — complete manual

Everything about running the [NullMoth nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)
on a passthrough NVIDIA GPU in a macOS 15 guest: the working configuration, how to
reproduce it, how to verify it, what is broken, and how to recover. Self-contained.

**Status: working.** GPU-composited desktop, Metal 3 for applications, driver-placed
**16 GiB BAR**, **8 GiB VRAM budget**. (The starting point for this work was 192 MB.)

## ⚠️ READ THIS FIRST — three traps that look exactly like driver failure

> **Each of these gives a macOS that boots, serves SSH, loads all four kexts, places BAR1 at
> 16 GiB with the full 8 GiB budget, reports `applyModeSetConfig -> 1` — and has no display
> at all.** They are *upstream* of the driver, so no amount of driver debugging finds them.

**1. A wrong or placeholder `osk` = no display, and nothing says so.** macOS starts and looks
healthy from the inside. The cursor you can move on the black screen belongs to your
**viewer**, not the guest. `screencapture` fails with *"could not create image from display
0"*, `system_profiler` lists no display, `virsh screenshot` returns a black frame. **It
survives an FLR, a GPU reset, a WindowServer restart and every `<video>` model.** →
**Substitute a real OSK before testing anything.** This is why a redacted copy of the domain
XML, kept for sharing, will not boot a working display — and it cost most of a day.

**2. SIP must be off *before* `install.sh` runs.** Otherwise: *"back up kernel collection /
Operation not permitted"*, which reads as a corrupt package or a bad download. It is neither
— the kernel collection carries the SIP `restricted` flag and root cannot read it with SIP
on. → **Set `csr-active-config`, reboot, confirm `csrutil status` says `disabled`, then
install.**

**3. Reset the GPU before a driver-phase boot.** With vfio the guest programs the physical
card and **a guest reboot does not reset it**, so booting several images in one session
leaves state that silently stops `applyModeSetConfig` — frames generated, panel dark. →
**FLR between boots.**

**And the two installers are not equivalent:** the tar ships `install.sh` (129 lines, files
plus kernel collection). **1401.app carries `nullmoth-setup.sh` (639 lines) that the tar does
not contain** — OpenCore config, recovery daemon, display-head publication. A tar-only
install gives four loaded kexts and no desktop. See *Installing the driver — two ways*.


**Contents** — [Quick start](#quick-start) · [Configuration](#the-configuration) ·
[Host setup](#host-setup) · [Guest setup](#guest-setup) · [Verification](#verification) ·
[Performance](#performance-and-how-to-measure-it) · [Known bugs](#known-bugs-and-limitations) ·
[Recovery](#recovery) · [Upstream findings](#upstream-findings) ·
[Investigation record](#investigation-record) · [Tooling](#tooling) · [Provisioning](#provisioning)

---

## Environment

| | |
|---|---|
| Host | ASUS ROG laptop, Intel Core Ultra 9 285H, NixOS, QEMU 11.1.1 / libvirt |
| Host display GPU | Intel Arc iGPU (stays on the host) |
| Passed-through GPU | NVIDIA RTX 5080 Max-Q, `10de:2c59`, mobile Blackwell GB203M |
| Guest | macOS 15.8.1 (24H32), OpenCore, NullMoth driver **1.0.9** (release v1.0.13) |
| Machine type | `pc-q35-10.2`, 12 vCPU, 32 GiB |
| Monitor | Sceptre O34, 3440x1440 @ 165 Hz, on the GPU's DP-1 |

The driver's own README is written for **bare metal + OpenCore**. This manual covers what
differs in a VM. Read theirs first.

---

## Quick start

Four things must be right. Together they take the driver from "loads but unusable" to
fully working.

| # | Setting | Where |
|---|---|---|
| 1 | `-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off` | libvirt XML, `<qemu:commandline>` |
| 2 | GPU **behind a PCIe root port** (guest bus `0x01`) | libvirt XML, hostdev address |
| 3 | Host BAR1 = **16 GiB** (`resource1_resize`, bit index 14) | host, while the VM is off |
| 4 | Driver at **shipped defaults** — no conf workaround | guest `/Library/GPUBundles/nvmtl/nvrm610.conf` |

**Setting 1 is the one that unblocks everything.** macOS will not resource a
passed-through device behind a PCIe root port while QEMU advertises ACPI hotplug for
bridges: it reads the card from config space and then assigns it nothing, because the
root ports publish zero-size `ranges`. With that property off, macOS resources the device
normally, `placeLargeBar1()` finally has the parent bridge it requires, and the driver
places its own BAR.

**OSX-KVM carries the same line commented out** in `OpenCore-Boot.sh`, which is where it
was eventually found:

```
# -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
```

---

## The configuration

### 1. QEMU: stop advertising bridge hotplug

```xml
<qemu:commandline>
  <!-- ... -cpu, isa-applesmc, -smbios ... -->
  <qemu:arg value='-global'/>
  <qemu:arg value='ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off'/>
</qemu:commandline>
```

**Verify it reaches QEMU.** libvirt silently drops attributes it does not understand —
`hotplug='off'` on a `<controller>` is one of them, and it cost hours here:

```bash
P=$(pgrep -f "guest=macos" | head -1)
tr '\0' '\n' < /proc/$P/cmdline | grep -c acpi-pci-hotplug-with-bridge-support   # must be >= 1
```

This is the general rule for this whole setup: **verify at the consumer, never at the
writer.** libvirt, OpenCore and games all discard configuration silently, and a dropped
setting looks identical to a setting that does not work.

### 2. Put the GPU behind a root port

Bus `0x01`, not `0x00`:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0' multifunction='on'/>
</hostdev>
```

Function 1 (GPU audio) goes at the same slot, function `0x1`.

This is the **normal Mac topology** — on real hardware a discrete GPU sits behind a root
port — so it is what `placeLargeBar1()` correctly expects. Keep
`<video><model type='none'/></video>`, and put USB hostdevs on an XHCI controller.

### 3. Set the host BAR to 16 GiB

`resource1_resize` takes the **bit index** of the size in the PCIe Resizable BAR
capability:

| bit | size | | bit | size |
|---|---|---|---|---|
| 8 | 256 MB | | 13 | 8 GiB |
| 11 | 2 GiB | | **14** | **16 GiB** |
| 12 | 4 GiB | | | |

```bash
G=/sys/bus/pci/devices/0000:01:00.0
D=/sys/bus/pci/drivers/vfio-pci

echo "" > $G/driver_override            # must be cleared before unbind
echo "0000:01:00.0" > $D/unbind
sleep 3
printf "14\n" > $G/resource1_resize     # 16 GiB
printf "vfio-pci\n" > $G/driver_override
echo "0000:01:00.0" > $D/bind
```

Verify it took — this is the step people skip:

```bash
python3 -c "l=open('$G/resource').readlines(); a=int(l[1].split()[0],16); b=int(l[1].split()[1],16); print((b-a+1)/2**30,'GiB')"
```

Do it **while the VM is off**: the guest driver reads the capability at startup.

`shrink-gpu-bar.sh` in this directory does the same thing and is the supported path —
**pass the size explicitly, its default is 1 GiB**:

```sh
sudo ./shrink-gpu-bar.sh 17179869184      # 16 GiB
```

---

## Host setup

### Bind the GPU to vfio-pci

As above. Also bind function 1 if passing the audio device through. `intel_iommu=on
iommu=pt` is already set in `modules/hardware/virtualization.nix`.

### Define and start

```sh
sudo ./vms/macos/setup-macos.sh     # idempotent; creates the disk, defines the domain
virsh -c qemu:///system start macos --console
```

First install only: in the OpenCore picker, Disk Utility → erase the large "sata" disk as
**APFS** → install macOS. Several reboots; OpenCore auto-selects the installer then the
installed volume.

---

## Guest setup

* **Driver**: `nvidia-macos-driver` release **v1.0.13** (driver 1.0.9). `NVRM` is
  byte-identical to 1.0.6; `NVRMFB` gained a vblank fix.
* **`nvrm610.conf`**: **shipped values**. No workaround needed once the BAR is real —
  that was the point of the exercise. The installer resets this file on every install, so
  re-check it afterwards.
* **boot-args**: `keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth
  amfi_get_out_of_my_way=0x1 amfi=0x80 debug=0x8 serial=1`.
  `nvrmsettle=15000` is **not needed** — remove it.
* **OpenCore**: `ResizeGpuBars=-1`, `ResizeAppleGpuBars=-1`, `DevirtualiseMmio=False`,
  `SecureBootModel Disabled`.

**Known OpenCore-side bug (worked around upstream):** `nvmtl-allow.txt` ships with its
`WindowServer` deny rule unreachable, because the allow-list is evaluated in rung order
and an earlier "everyone" rule wins. It works here; upstream it needs reordering.

---

## Installing the driver — two ways, and the traps

**Choose by what your display does, not by preference.**

| what you see | what to do |
|---|---|
| macOS reaches a **login window** on the passed-through card | **Use 1401.app.** It is NullMoth's installer and does the whole job: files, kernel collection, OpenCore config, display-head publication. Get `1401-Mac-*.dmg` from the driver's releases, run it in the guest, reboot. |
| macOS **boots but shows nothing** — cursor on black, frozen Apple logo, `screencapture` failing with *"could not create image from display 0"* | **Do not reach for the tar first.** Work the checks below in order. The usual cause is the OSK or a dirty GPU, not the driver. |

### Trap 1 — the OSK. This one costs the most time.

**A wrong or placeholder `osk` in `isa-applesmc` gives you a macOS that boots, serves SSH,
loads all four kexts, places BAR1 at 16 GiB with the full 8 GiB budget, reports
`applyModeSetConfig -> 1` — and has no display at all.**

Every internal signal says the driver is working. The display is never initialised. The
symptoms point everywhere except the cause:

| symptom | meaning |
|---|---|
| `screencapture` → *"could not create image from display 0"* | macOS has no display |
| `system_profiler SPDisplaysDataType` lists no display | same |
| external monitor: movable cursor on black | that cursor is the **viewer's**, not the guest's |
| QEMU console: frozen Apple logo + progress bar | last frame the guest ever sent |
| `virsh screenshot` → black 1280x800 PNG | QEMU is fine; the guest draws nothing |

**It survives an FLR, a GPU reset, a WindowServer restart, and every `<video>` model**,
because it is upstream of all of them. No amount of driver debugging will find it.

**Where this bites:** building a test domain from a config that ships a placeholder OSK.
If you keep a redacted copy of the domain XML for sharing, that copy will not boot a
working display. Substitute a real OSK before testing anything with it.

### Trap 2 — SIP must be off before `install.sh` runs

`install.sh` dies at *"back up kernel collection / Operation not permitted"*, which reads
as a corrupt package. It is neither: the kernel collection carries the SIP `restricted`
flag and root cannot read it with SIP on.

Set `csr-active-config` (`<430A0000>` is the tested value) in OpenCore, **reboot**, verify
`csrutil status` says `disabled`, and only then install. Check it first:

```bash
csrutil status                                       # must be: disabled
nvram -p | grep csr-active-config                    # must not be %00%00%00%00
lspci -nnk -s 01:00.0 | grep -i "driver in use"      # must be vfio-pci
```

### Trap 3 — a driver-phase boot needs a freshly reset GPU

With vfio the guest programs the physical card, and **a guest reboot does not reset it**.
Booting several macOS images in one session leaves state that silently prevents
`applyModeSetConfig` from running — frames generated, panel dark, nothing pointing at the
cause. Reset before a driver-phase boot:

```bash
sudo scripts/gpu-to-host.sh
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/reset
sudo scripts/gpu-to-vfio.sh 16GiB
```

### Trap 5 — updating needs `--efi`, and a stray disk hides the ESP

`nullmoth-setup.sh` verifies which partition OpenCore started from, by reading OpenCore's
`boot-path` NVRAM variable. **If that variable is empty it stops with "OpenCore's startup
partition could not be confirmed"** even after naming the right candidate. Pass the
partition explicitly — `diskutil list` shows it, and it is the small EFI one:

```bash
sudo ./nullmoth-setup.sh \
  --pkg ~/Downloads/nullmoth-nvidia-<ver>.tar.gz \
  --sha <published sha256> \
  --tool ~/NullMothSafe.efi \
  --app  ~/1401-bin \
  --efi  disk0s1
```

**And check that the guest can see the ESP at all.** An extra disk in the domain shifts the
disk numbering, and a stray recovery medium (`BaseSystem.img`) left attached as `sdc` with
its own `boot order` was enough to make the OpenCore ESP invisible to `diskutil` — so the
updater reported *"no OpenCore config for this Mac on any connected disk"*. Detach anything
that is not the macOS disk and the OpenCore disk:

```
sda  the macOS disk
sdb  the OpenCore ESP
```

That is exactly what `macos.xml` defines. If `virsh domblklist` shows more, the running
domain is not the one in this repo — `virsh undefine --nvram` and define it again.

### Trap 4 — the tar is half an install

`nullmoth-nvidia-*.tar.gz` ships `install.sh` (129 lines): files plus kernel collection.
**1401.app additionally carries `nullmoth-setup.sh` (639 lines) which the tar does not
contain**, and that script:

* edits the OpenCore config — `boot-args`, `csr-active-config`, and the
  `com.apple.iokit.IONDRVSupport` entry in `Kernel.Block`
* installs `com.nullmoth.crashcheck.plist` and `com.nullmoth.recover.plist`
* resolves which ESP actually booted, from OpenCore's own `boot-path` NVRAM variable
* runs display bring-up diagnostics against `debug.nvaccel_heads_published`,
  `debug.nvaccelfb`, `debug.nvrmfb_agdc`, `debug.nvaccel_iop`

A tar-only install gives four loaded kexts, a placed 16 GiB BAR, an 8 GiB budget, generated
frames, and no desktop. To run it by hand it must sit beside `nullmoth-install.sh` and be
given every input:

```bash
sudo ./nullmoth-setup.sh \
  --pkg  /path/to/nullmoth-nvidia-<ver>.tar.gz \
  --sha  <its published sha256> \
  --tool /path/to/NullMothSafe.efi \
  --app  /path/to/1401.app/Contents/MacOS/1401
```

It refuses to run as a loose copy; `--tool` and the audited installer both come from
`1401.app/Contents/Resources/` in the release zip.

## Verification

```bash
# driver reached pass 2 and claimed the GPU
ioreg -l -w0 | grep '"nvrm-autogo"'                 # -> "up"

# all four kexts loaded
kmutil showloaded | grep -c nullmoth                # -> 4

# a display exists and is being driven
ioreg -rc IODisplay -w0 | grep -c -- "+-o "         # -> 1

# THE NUMBER THAT MATTERS — the VRAM budget
sysctl -n debug.nvrmfb_vram_budget_bytes            # -> 8589934592  (8 GiB)

# the BAR the driver placed for itself
ioreg -l -w0 | grep '"nvrm-bars"'
#   bar1@0x14:0x1000000000+0x400000000          <- 16 GiB
```

Driver log (serial console, or `dmesg`) should read:

```
bar1: Resizable BAR capability @0x134 says BAR1 = 16384 MB (sizes supported mask 0x4000)
bar1: host bridge 64-bit window 0x1000000000-0x17ffffffff (ACPI _CRS), CPU reaches 40 bits
bar1: placing BAR1 16384 MB @0x1000000000, BAR3 32 MB @0x1400000000 ... PLACED
```

**`PLACED` means the driver did the BAR placement itself** — the mechanism the author
designed, and the thing that was unreachable before the root-port fix.

### Capturing the driver's log

The domain writes the guest serial to a file (temporarily configured at
`/tmp/macos-serial.log`); `strings` it for `NVRM-xnu:` / `NVAccel:` / `NVRM-fb:` lines.
With `<video>=none` there is no emulated console, so serial is the only channel.

---

## Performance and how to measure it

Reference run — `bench.sh`, 18 s autonomous drag, 8 GiB budget:

```
flips 2438   WindowServer 16.43 s -> 6.74 ms/flip
grants +2   parks +0   refusals +0
compositor flips: 2436 -> 135.3 fps
```

**Watch `parks` and `refusals`, not the fps headline.** Continuous-drag fps varies
91-140 fps between runs on identical configuration; parks, refusals and ms/flip are the
stable indicators.

**And note what continuous-drag fps does *not* catch:** the same session reported its
best-ever figures while window switching was failing outright. See "park leak" below —
**refusals per window switch is the metric that exposes it.**

**Do not enable `NVMTL_HWPOOL=1`.** It installs private pool classes and correlates with
a kernel panic.

---

## Known bugs and limitations

Real, current, driver-side. None is fixed by configuration.

### 1. A display-mode transition wedges the display — breaks the session

After a fullscreen app runs, or any display-mode transition, the panel alternates between
live content and a dead client's last frame — or freezes with only the cursor moving.
Progression seen in one session:

| event | result |
|---|---|
| exclusive fullscreen | steady flash: splash ↔ game frame |
| switched to borderless, vsync Single | bursty flash: game frame ↔ desktop |
| left alone | partner degraded to a dark screen |
| **WindowServer restart** | **stable — flash gone** |
| borderless → fullscreen | **wedged again** |

**Guest reboots do not clear it:** with vfio the guest driver programs the physical GPU,
and a guest reboot never resets it. **Run games windowed/borderless** — that avoids the
trigger entirely.

What it is *not*, each falsified by measurement:

* **Not the flip path** — `iop_flips 16766`, `iop_ok 16863`, `iop_fail 0`,
  `iop_flip_stale 0`, `iop_flip_refused 0`. Every flip succeeds by the driver's own
  accounting; `flip_stale = 0` because it sincerely believes the surface is current.
* **Not the composite** — `screencapture` returns a stable, correct desktop across eight
  rapid captures while the panel alternates.
* **Not async flip recycling** — `debug.nvaccel_iop_async=0` changes nothing.
* **Not a late-published framebuffer** — `debug.nvaccelfb=3` does not take (stays 1) and
  `agdc_maxfb` is 1.

Mechanism: the composite source changes underneath a running WindowServer, which keeps
presenting to a surface bound before the change. The driver's own source comment names
the remedy: *"WindowServer composites it only after a WindowServer restart"*.

### 2. Park leak — window-switch drag lag

`kexts/NVRM/fb/nvrm-fb.cpp:1261`:

```c
SInt64 before = OSAddAtomic64(want, &gVramMappedBytes) + gVramParkedBytes;
if (before + want > budget) { ...refuse... }
```

`gParkedForever[24]` holds console/scanout-overlapping allocations and **never releases
them**; their bytes are charged against every later grant. Measured: **8-16 VRAM refusals
per window switch**, climbing, while `mapped` is 120 MB of an 8 GiB budget — so parked
bytes are consuming nearly the whole budget.

Symptom: continuous dragging is fine; the **first drag after switching windows** stalls.

* A **reboot clears it** (in-kernel state), so it returns progressively.
* **Running a game accelerates it** — many surfaces cycled.
* `nvaccel_vm_refused` counts "refused by the framebuffer". **The parked figure itself is
  not exposed as a sysctl** and is inferred from the refusal condition, not read.

### 3. Shader translation is the bottleneck

`libnvmtl_translate.dylib` (Metal → SPIR-V, Rust) dominates. During gameplay:
**2338 of ~2500 samples in `nvmtl_translate`** vs 85 in `Render`. Entering a game world
stalls for several seconds while pipelines compile, then recovers — slow, not broken.
Lowering quality presets reduces the number of pipelines.

### 4. Upscalers produce a wrong image

With `MetalFXMode=Spatial` + `AntiAliasing=MetalFXSpatial` + `DLSS=UltraPerformance` the
game renders a **partially formed image**: it renders at reduced internal resolution and
expects the upscaler to reconstruct it, which the translation layer does not implement.
Fix — all off, render native:

| setting | value |
|---|---|
| MetalFX / AntiAliasing | `Off` / `TAA` (or `None`) |
| DLSS (+ frame generation) | `Off` |
| NVIDIA Reflex Low Latency | `Off` |
| Dynamic resolution scaling | lowest factor `1.0` |

### 5. `screencapture` cannot see a game's output

Games present through the driver's **zero-copy direct scanout**, bypassing the
WindowServer composite. `screencapture` therefore returns only the desktop, even with the
game frontmost and running. Use the game's own screenshot function.

### 6. Display modes and resolution changes

Only the native resolution and refresh are published — **no lower refresh rate** is
offered at 3440x1440. Changing resolution **wedges the display and can panic the
kernel**; it is the context in which a panic was reproduced. Treat resolution changes as
destructive.

---

## Recovery

Cheapest first.

| # | step | effect |
|---|---|---|
| 1 | **`sudo killall -9 WindowServer`**, then log in | Re-binds the scanout. ~30 s, logs out. **Verified.** Keeps the VM, the BAR and the config. |
| 2 | **Host FLR**: unbind vfio-pci, `echo 1 > .../reset`, rebind, restart VM | **Verified.** Costs a VM restart. |
| 3 | Guest reboot | Clears the parked bytes, but **does not** clear a scanout wedge. |

**Does nothing** (all tested): Metal shader-cache clear, `killall Dock`, wallpaper change,
display sleep/wake, `debug.nvaccelfb=3`, `debug.nvaccel_iop_async=0`, `nvrmctl` (only
`go`/`good`/`state` — no surface or display reset).

If the display wakes but the WindowServer's CPU time sits frozen, that is the wedge, not a
sleep state — go to step 1.

### Avenues that do NOT work — do not spend time on them

Each was applied and **verified present at QEMU** before being ruled out:

* per-root-port `hotplug=off`, `x-do-not-expose-native-hotplug-cap=on`,
  `pref64-reserve`, `mem-reserve`, `power_controller_present=off`
* an explicit option ROM (`<rom file=…>`, verified via `romfile=` in the cmdline)
* `ResizeGpuBars` in any value, `DevirtualiseMmio=true`, `phys-bits=40`,
  `q35-pcihost.pci-hole64-size`, `x-no-mmap=on`, `npci=0x2000`
* OpenCore `DeviceProperties` injection of the root ports' `ranges` — **tested**: the
  injected value does not reach the node, because IOPCIFamily reads `ranges` from the
  firmware device tree, not the IORegistry
* an SSDT overriding the root ports' `_CRS` (the SSDT route dies if QEMU declares `_CRS`
  as a *name* rather than a *method*)
* disabling all kexts, `SSDT-DTGP` off, `MacPro7,1` + Cascade Lake platform
* clearing Metal shader caches (made startup slower, changed nothing)

---

## Upstream findings

Fifteen findings for the driver author. Findings 1-11 are from driver 1.0.1; 12-15 from
1.0.9 with the configuration working. **Finding 12 is the most serious.** Findings 1, 6, 7
and 10 were symptoms of the GPU being forced onto bus 0 and should be re-checked before
acting on them; **Finding 11 is superseded** and corrected below.

<details open>
<summary><b>1 — the 40 s boot-hold cap expires before the 100 s auto-go</b></summary>

The display never arms with WindowServer up, making the Metal desktop unreachable, i.e.
the README's *"your NVIDIA card drives the display"* case fails. A timing collision
between the cap and the auto-go delay. Workaround as used here: a boot-arg that settles
the timing (`nvrmsettle=15000`), no longer needed now the BAR placement succeeds.
</details>

<details>
<summary><b>2 — <code>nvmtl-allow.txt</code> ships with its WindowServer rule unreachable</b></summary>

The allow-list is evaluated in rung order, so the shipped "everyone" rung shadows the
`-Name denies` rung. Reorder, or document the precedence — the file reads as though the
deny applies.
</details>

<details>
<summary><b>3 — WindowServer saturates a core to composite</b></summary>

Compositing alone consumes a full core. Better once the BAR was real; worth re-measuring.
</details>

<details>
<summary><b>4 — no lower refresh rate is published at the native resolution</b></summary>

Only 165 Hz at 3440x1440. No way to pick a lower rate, which would help when the
translator is the bottleneck.
</details>

<details>
<summary><b>5 — changing resolution wedges the display, and is the context of a KERNEL PANIC</b></summary>

A resolution change is destructive and the same code path panicked. See the manual's
"Display modes" section.
</details>

<details>
<summary><b>6 — the shipped <code>nvrm610.conf</code> throttled the compositor by 3-4x</b></summary>

`NVMTL_VRAM_WS_NONIMAGE_MB=0` / `HEADROOM_MB=256` / `RES2_WS=0` starved it: dragging ran
at 16-21 fps instead of 58-80. **A symptom of the 192 MB budget** — with a real BAR the
shipped values are correct and no workaround is needed.
</details>

<details>
<summary><b>7 — a 256 MB BAR leaves the compositor ~13 MB of headroom</b></summary>

Consequence of the small budget; no longer applicable with a 16 GiB BAR.
</details>

<details>
<summary><b>8 — <code>NVMTL_HWPOOL=1</code> installs private pool classes and correlates with a panic</b></summary>

Do not enable.
</details>

<details>
<summary><b>9 — <code>gParkedForever</code> leaks the VRAM budget permanently</b></summary>

Until nothing can allocate. Quantified as Finding 13 below.
</details>

<details>
<summary><b>10 — the BAR table depends on IODeviceMemory descriptors, so a >4G BAR silently disables it</b></summary>

`bars[FB]` becomes BAR3 and `go(2) failed`. **Suggested hardening:** read the BAR *size*
from the Resizable BAR capability (which works at every size) and fall back to probing
`configRead32(0x10 + 4*bar)` when no descriptor matches. **The "256 MB is the only value
that works" advice attached to this finding is superseded.**
</details>

<details>
<summary><b>11 — <code>&gt;= 4 GiB BAR is unusable in a VM</code> — SUPERSEDED</b></summary>

**A large BAR works in a VM.** The blocker was never the BAR size: macOS would not
resource the device behind a root port, so the GPU sat on bus 0 and `placeLargeBar1()`
failed with `bar1: parent root port not found`. Fix that (one QEMU property) and a 16 GiB
BAR is placed successfully with an 8 GiB budget. The original measurements remain accurate
*for a GPU on bus 0*: 8 GiB → QEMU died with a non-canonical address
(`0x8408400000000000`); 4 GiB → macOS assigned above 4G with no descriptor published. That
8 GiB crash no longer occurs either, because macOS now programs a sane address instead of
garbage — it never generates one when the device is resourced normally.
</details>

<details open>
<summary><b>12 — the scanout binding survives a display-mode transition (breaks the session)</b></summary>

The only defect that makes the machine unusable, and the only one needing a workaround to
use at all. See "Known bugs" §1 for the symptom progression, the four hypotheses falsified
by measurement, and the author's own comment naming the remedy.

**Request:** a way to re-bind the scanout without restarting the WindowServer — an
`nvrmctl` subcommand, or a sysctl that forces a re-bind — would turn a session-breaking
bug into a recoverable one.
</details>

<details open>
<summary><b>13 — the park leak eventually consumes the entire budget (quantified)</b></summary>

Mechanism and measurements in "Known bugs" §2. **Two requests:**

1. **Expose `gVramParkedBytes` as a sysctl.** There is no way to read it today; the
   ~7.9 GiB figure is *inferred* from the refusal condition. Diagnosing this needs the
   counter.
2. **Release parked allocations** when the console/scanout surface they overlap is gone,
   or stop charging them against every later grant.
</details>

<details>
<summary><b>14 — Metal → SPIR-V translation dominates runtime</b></summary>

2338 of ~2500 samples in `nvmtl_translate` vs 85 in `Render`. **Request:** a persistent
on-disk pipeline cache. The world-load stall is the visible symptom; the steady-state cost
is what keeps frame rates low.
</details>

<details open>
<summary><b>15 — <code>NVRM.kext</code> cannot be built from public sources</b></summary>

Reported because it blocks third-party fixes for Findings 12-14. Three independent gaps,
each verified:

1. **No build script compiles the kexts.** `build/` emits only NVAccel, NVRMAGDC, the
   plugin, the translator and NVK. `kexts/NVRM/rmcc.py:6` references `build-nvrm.sh`,
   which is not in the tree.
2. **Public `open-gpu-kernel-modules` 610.57.04 has no Darwin support.** `grep -ri darwin`
   → zero hits; `nvport/debug.h` reaches `#error "Unsupported target OS"`; and
   `make TARGET_OS=Darwin` exits 0 while writing an **ELF** object (magic `7f 45 4c 46`).
3. **Unpublished artifacts required** — `build-nvrm.sh`, `libnvkernel.a`,
   `$NV/_out/Darwin_x86_64/compile_cmds.sh`. `accel_build.sh` exits 1 against a clean
   clone; `grep -r compile_cmds` in the public tree returns nothing.

**Additionally:** `destroyScanoutResource` and `setupScanout` are declared in
`kexts/NVRM/accel/iofam/IOAccelLegacyDisplayMachine.h` but are **headers only** — the
implementation is not public. So Finding 12 cannot be patched from outside even in
principle.

**Request:** publish `build-nvrm.sh`, or the Darwin port of the kernel modules, or
`libnvkernel.a`.
</details>

---

## Investigation record

Durable findings from the work that produced this manual. The full chronological history,
including every dead end and the layering of corrections, is in git:
`git log --follow -- vms/macos/DRIVER-INSTALL-NOTES.md`.

### The root cause, in one chain

```
ICH9-LPC bridge hotplug ON (QEMU default)
 → macOS sets IOPCIHPType=0x21 and will not resource root-port devices
  → root ports advertise zero-size `ranges`
   → GPU forced onto bus 0
    → placeLargeBar1() has no parent bridge ("parent root port not found")
     → the driver cannot place its own BAR
      → dependence on macOS's own placement
       → corrupted addresses above 4 GiB
        → 192 MB budget ceiling
```

The fix closes it at the first link.

### The measurement that broke it open: the tri-VM comparison

Identical QEMU, GPU behind a root port, all levers applied and verified:

| guest | IRQ | BARs | root port windows |
|---|---|---|---|
| **Linux** | **11** | **all** — BAR0 64 MB, BAR1 256 MB at `0x1000000000` (above 4G), BAR3 32 MB, BAR5 I/O | `prefetchable memory range [0x1000000000 ...]` |
| **macOS** | **0** | **none** | `assigned-addresses` = its own 4 KB register BAR only |

**Linux resources the card perfectly behind the same root port on the same QEMU.** That
exonerated QEMU, the device model, the ACPI tables, the root port and its windows — and
localised the fault inside macOS's PCI resource assignment.

The zero-size `ranges`, read as a value:

```
root port S10@2
  "class-code" = <00040600>            PCI-to-PCI bridge
  "ranges"     = < 00000082 00000000 00000000  00000082 00000000 00000000  00000000 00000000
                   000000c2 00000000 00000000  000000c2 00000000 00000000  00000000 00000000
                   00000081 00000000 00000000  00000081 00000000 00000000  00000000 00000000 >
```

Three window descriptors — 32-bit MMIO (`0x82`), 64-bit prefetchable (`0xc2`), I/O
(`0x81`) — every size **zero**. macOS trusts the firmware; Linux ignores `ranges` and
programs the bridge's window registers itself, which is why Linux worked.

### Hypotheses falsified by measurement — do not re-tread

Labelled so nobody repeats them. Each was disproved by data, not argument.

| hypothesis | how it died |
|---|---|
| memory pressure caused the flash/stall | fixed (8 GiB, parks/refusals 0); drag stall gone, flash remained |
| a QEMU bug in BAR assignment | firmware assignment measured correct with no OS running |
| OpenCore writes a garbage BAR address | four-way isolation: Linux, Windows, macOS-at-picker all fine; only boot.efi running produced it |
| async flip recycling the scanout buffer | 15419 async flips, 0 refused, 0 dropped while flashing |
| an orphaned surface left in the flip chain | `iop_flip_stale 0`, `iop_fail 0` |
| the device tree's missing `interrupt-map` | working bus-0 devices have no `interrupt-map` either; they use `IOInterruptSpecifiers` |
| OpenCore could supply the root ports' `ranges` | injected value never reached the node |
| the game's own buffering (`VsyncEx=Triple` + fullscreen) | switching to Single + borderless changed the flash, did not remove it |
| WindowServer-side staleness | `screencapture` showed a correct composite throughout |
| a second framebuffer/pipe contending for head 0 | `agdc_maxfb 1`, one framebuffer registered |
| the host IOMMU refuses to map a 16 GiB BAR | it does not; a 16 GiB BAR works |
| `placeLargeBar1()` is buggy | it is correct; it simply never had a parent bridge |

### The driver's runtime lever inventory

Useful, and recorded so it is not rediscovered. **None fixes Finding 12.**

* **Settable via `callPlatformFunction`**: `NVRMBootRaster`, `NVRMBootScreen`,
  `NVRMBootScreenDone` (releases the boot-screen buffer), `nvFlipToSurfacePure`,
  `nvNewAccelClient`, `nvNewAccelClient`.
* **Flip path**: `debug.nvaccel_iop_async` (1 = async zero-copy), `_async_flips`,
  `_async_refused`, `_async_drop`, `_iop_flip_hit/_miss/_stale/_refused`, `_iop_blank`,
  `_iop_ok_h0..h3`, `_iop_empty`, `_iop_src_surf`.
* **Framebuffer / VRAM**: `debug.nvrmfb_vram_budget_bytes`, `_mapped_bytes`, `_grants`,
  `_grant_bytes`, `_releases`, `_release_bytes`, `debug.nvrmfb_vramtest` (grant N × 8 MB,
  0 = release all).
* **Display**: `debug.nvrmfb_agdc`, `_agdc_maxfb`, `_agdc_fbmap`, `_agdc_refused`,
  `_agdc_k5*`. `debug.nvaccelfb` (1 = register the framebuffer with the accel display
  machine, 2 = family sweep, 3 = give a late framebuffer a pipe).
* **Accel VM**: `debug.nvaccel_vm_alloc/_dealloc/_refused`, `_res_new/_res_free`,
  `_map_commit/_map_release`.
* `debug.*` sysctls are **runtime-only**; nothing persists across a reboot.

### Tooling lessons — these cost a lot of time

* **`qemu-nbd --disconnect` while a filesystem is mounted leaves the mount stale**, and
  every later read/write fails with `Errno 5` while `qemu-img check` still reports the
  image as clean. That is how the OpenCore config was corrupted once. Always `umount`
  first, `sync`, and use `--fork`. The `fsck.fat "Read 512 bytes at 0: Input/output
  error"` and `plistlib OSError: [Errno 5]` symptoms were **both** this artifact, not disk
  corruption — `dd` read every image perfectly.
* **Verify at the consumer, never at the writer.** Every silent-drop incident in this
  project had the same shape.
* **Don't `pkill -f` patterns that match your own shell** — it kills the shell.
* **`sudo-env` has a private `/tmp`**, so scripts invoked through it must live under
  `/home/tianyixia/`.
* **HMP parses the filename argument as an expression**, so `pmemsave 0xe0000 0x1000
  /home/...` fails with `invalid char 'h'`. Quote it.
* **Check a guest has `Quartz`/`AppKit` before trusting an empty window-list result.**
  macOS 15's `/usr/bin/python3` lacks them, so `CGWindowListCopyWindowInfo` raises
  `ModuleNotFoundError` and looks like "no window".
* **macOS has no `timeout`, no `setpci`/`lspci`, and no `/usr/include`.**
* `sshd`-driven `ps aux` renders paths in **uppercase**, so case-sensitive `pgrep -f`
  patterns miss (`grep -i` instead).

### Backups

**Disk images.** One image is current; everything else is stashed, not deleted:

| path | what |
|---|---|
| `/var/lib/libvirt/images/macos.img` | **the live image** — the one `macos.xml` uses |
| `/var/lib/libvirt/macos-image-stash/` | `macos.img.20261008-0151.working-with-driver` (99 GiB), `macos.img.before-restore` (64 GiB), `macos.img.20261007-0535.pre-driver` (36 GiB), `macos-clean.img` (36 GiB) |

The stash is 218 GiB apparent but only **46 GiB exclusive** on btrfs, because they are
reflinks sharing extents with each other. Stashing by `mv` within the same filesystem
costs nothing and preserves the sharing — copying would not. `btrfs filesystem du` shows
the real cost; `du` does not.

**OpenCore.** `OpenCore.qcow2` is the live ESP. `OpenCore.qcow2.20261007-0539.pre-nullmoth`
is the stock OSX-KVM config from before any of this work — note it is *not* a known-good
fallback: it carries a different kext set (Broadcom Bluetooth, AGPMInjector, USBPorts) and
no display or BAR settings, and a macOS image booted against it does not display.

**Driver.** In the guest: `~/nvmtltest/nvrm610.conf.good`, `~/nvmtltest/pre-1.0.9/`,
`~/pkgroot109/pkgroot`. On the host: `/tmp/nm-src` (driver git, tags to v1.0.13),
`/tmp/nm106`, `/tmp/nm109`. `nullmoth-setup.sh` also leaves its own
`config.plist.nullmoth-<timestamp>` beside the live config on the ESP, and a driver backup
under `/Library/NullMoth/backup-<timestamp>`.

---

## Tooling

`bench.sh` — autonomous drag benchmark; reports flips, ms/flip, grants/parks/refusals,
mapped/budget. Guest copies in `~/nvmtltest/`.

```sh
~/nvmtltest/bench.sh "label" 18
```

`dragload.m`, `surfbench.m`, `shaderbench.m` — targeted microbenchmarks (drag load,
surface throughput, shader compilation).

`shrink-gpu-bar.sh` — **the tool that sets BAR1 size on the host.** Despite the name it
sets any size, and it is the supported way to do step 3 of the configuration:

```sh
sudo ./shrink-gpu-bar.sh 17179869184      # 16 GiB  <- what this setup needs
```

**Its default (no argument) is 1 GiB, which is wrong for this configuration** — always
pass the size explicitly. `17179869184` = 16 GiB, `8589934592` = 8 GiB, `268435456` =
256 MB.

`setup-macos.sh` — idempotent domain/disk setup. `install-progress` — live progress/ETA
while macOS installs into the domain. `mmio-probe.py` — read-only GPU inspection from
inside the guest (identity, BARs, `IODeviceMemory` descriptors); useful when the driver's
BAR table looks wrong.

The domain's serial is written to a file; `strings` it for driver logs.

---

## Provisioning

| Piece | Path | Notes |
|---|---|---|
| Guest disk | `/var/lib/libvirt/images/macos.img` | 1 TiB **thin** qcow2, `default` pool |
| OpenCore | `~/OSX-KVM/OpenCore/OpenCore.qcow2` | bootloader; supplies AppleSMC + board-id |
| Recovery media | `~/OSX-KVM/BaseSystem.img` | Apple recovery build `082-33203`, raw 3.2 GB |
| Firmware | `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` | OVMF from nixpkgs |
| NVRAM | `/var/lib/libvirt/qemu/nvram/macos_VARS.fd` | created on first boot |
| Domain XML | `vms/macos/macos.xml` | registered via `modules/hardware/virtualization.nix` |

Nothing is pinned to a macOS release: swapping `BaseSystem.img` for a newer recovery image
is the only step a newer release would need.

### Caveats

1. **Laptop MUX.** On this ASUS the dGPU reaches the internal panel through a MUX. The
   external monitor on the card's DP-1 works; confirm the display path before concluding a
   driver bug.
2. **RTX 5080 Max-Q (`10de:2c59`) is not a target upstream tested** — they tested an RTX
   5060 (`2d05`). It works here regardless.
3. **`NVRM.kext` is not buildable from public sources** (Finding 15), so the display bugs
   must go upstream.
4. **Run games windowed/borderless** — see Known bugs §1.
