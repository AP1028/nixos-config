# Installing the NullMoth driver — investigation results

What the script does, what it does not do, and the exact settings required.
Derived from `package/install.sh`, the driver's README, and — most usefully —
the maintainer's own working implementation in `app/Resources/nullmoth-setup.sh`.

## Direct answer: script alone is NOT enough

`install.sh` verifies and installs files, then **warns** that it cannot do the
rest. Verbatim from its step 6:

```
step "6. boot-args"
ba=$(nvram boot-args 2>/dev/null | cut -f2-)
for a in nvfb=1 nvaccel=1; do case " $ba " in *" $a "*) ;; *) echo "   NOTE: boot-args lack '$a' — add it in your OpenCore config.plist (see README)";; esac; done
```

It contains no handling of `boot-args`, `csr-active-config`, `ScanPolicy`, SIP,
or Secure Boot. Those must be set separately.

### Its three hard gates

```
[ "$(uname -m)" = x86_64 ]                 || die "Intel/x86_64 only"
v=$(sw_vers -productVersion); [ "${v%%.*}" = 15 ] || die "macOS 15 required"
ioreg -r -c IOPCIDevice -d 1 | grep -q '"vendor-id" = <de100000>' || die "no NVIDIA GPU found on PCI"
```

Gate 3 is the one passthrough unlocks. Gates 1 and 2 already pass.

### What the script actually does, in order

1. Checks the three gates above.
2. `shasum -a 256 -c SHA256SUMS` — refuses on mismatch.
3. **Test-builds the Auxiliary Kernel Collection** into a temp dir and confirms
   all four kexts appear in it. Nothing is written yet. `CHECK=1` stops here.
4. Backs up existing kexts/bundles and the live `.kc` to
   `/Library/NullMoth/backup-<timestamp>`.
5. Copies `NVRM/NVAccel/NVRMFB/NVRMAGDC.kext` → `/Library/Extensions`;
   `NVMTLDriver.bundle`, `NVIDIAShared.bundle`, `nvmtl/` → `/Library/GPUBundles`;
   firmware → `/Users/Shared/nvfw`; fixes ownership/modes.
6. `kmutil create -n aux --volume-root / --allow-missing-kdk ...` to rebuild
   `/Library/KernelCollections/AuxiliaryKernelExtensions.kc`, then re-inspects
   it and dies if any of the four is missing.
7. Warns about missing boot-args.

`uninstall.sh [backupdir]` removes the files and rebuilds the collection, or
restores wholesale from a backup directory if given one.

## The exact settings, verified against 1401

From `app/Resources/nullmoth-setup.sh` — the maintainer's own implementation, so
this is authoritative rather than inferred:

```sh
WANT_ARGS="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80"
DROP_ARGS="nv_disable=1 -wegnoegpu"     # both hide the NVIDIA card from macOS
SIP_BITS=$((0x0A43))
```

Note their implementation **merges** the SIP bits rather than overwriting:
`want=$(( cur | SIP_BITS ))`. If SIP is currently fully enabled (`0x0000`), the
result is exactly `0x0A43`, which is what the README writes as `<430A0000>` —
that literal is the little-endian byte layout of `0x0A43`. In a plist it is the
4 data bytes `43 0A 00 00`, i.e. base64 `QwoAAA==`.

| Setting | Value | Applies to |
|---|---|---|
| `NVRAM → Add → 7C436110-… → boot-args` | `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80` | guest |
| `NVRAM → Add → … → csr-active-config` | data `43 0A 00 00` (`QwoAAA==`) = `0x0A43` | guest |
| `NVRAM → Delete → …` | add `boot-args` **and** `csr-active-config` | guest — so OpenCore rewrites them every boot |
| `Misc → Security → SecureBootModel` | `Disabled` | guest (already is) |
| `Kernel → Block` | add `com.apple.iokit.IONDRVSupport`, `Strategy=Exclude`, `Enabled=true`, `Arch=Any` | guest |
| `UEFI → Quirks → ResizeGpuBars` | `13` | **HOST ONLY** |
| `Booter → Quirks → ResizeAppleGpuBars` | `-1` | **HOST ONLY** |

### Why the BAR settings do not apply to us

`ResizeGpuBars` makes the **host's** UEFI firmware reprogram the physical GPU's
BARs to 8 GB. Inside QEMU the guest sees an emulated root complex and the
passed-through GPU's BARs as exposed by the vfio hostdev; a guest bootloader
cannot reprogram them. Their own README says the *macOS installer* needs the
opposite values (`ResizeAppleGpuBars 0`, `ResizeGpuBars -1`) — i.e. these are
properties of the bare-metal boot, not of macOS. For a VM: skip them, and if
BAR sizing ever matters it is a host OpenCore change, not a guest one.

`IONDRVSupport` blocking is different — it is a macOS kernel-extension policy,
so it does carry over and is worth setting.

## Two routes to apply the guest-side settings

**Route A — edit OpenCore's `config.plist` offline (what the README prescribes).**
Mount `~/OSX-KVM/OpenCore/OpenCore.qcow2` with `qemu-nbd`, patch the ESP's
`/EFI/OC/config.plist`, unmount. Must be done with the VM **shut down**. This
keeps the settings in the bootloader, which is what the driver documents, and
survives anything the guest does to its own NVRAM.

**Route B — set NVRAM from inside the guest** (now possible because SSH works):

```sh
sudo nvram boot-args="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80"
sudo nvram csr-active-config=%43%0A%00%00
sudo reboot
```

Faster, no shutdown needed, but NVRAM-only: on a Mac whose bootloader rewrites
`boot-args` each boot it can be reverted, and it does not set
`SecureBootModel`/`IONDRVSupport` (those are bootloader-side). Use this for a
quick `-nvoff` recovery toggle; use Route A for the real configuration.

Note `csr-active-config` **only takes effect on reboot**, and `csrutil status`
will report SIP disabled only after one.

## RESOLVED — the passthrough works now

The blocker was the **BAR size**, and it is fixable entirely from Linux. No BIOS
change is required, and Resizable BAR can stay enabled on the host.

### The symptom was a non-canonical address

The GPU's BAR1 was presented at **`0x8508000000000000`**, which is not a valid
x86-64 address (outside both the user range `< 0x800000000000` and the kernel
range `>= 0xffff800000000000`). It equals **`0x85080000 << 32`** — a 32-bit MMIO
base written into the *high* dword of a 64-bit BAR, low dword zero. This matches
a known EDK2 bug class in `PcatPciRootBridgeParseBars`, which combines a BAR's
halves with `LShiftU64(UpperValue, 32)` and chooses an aperture from whether the
base is below 4 GiB. It is **not** an intended address.

### The fix: shrink BAR1 from the host

`resource1_resize` takes a **bit index**, not bytes:
`0`=1 MB, `1`=2 MB, … `10`=1 GiB, `11`=2 GiB, **`12`=4 GiB**, `13`=8 GiB.

Measured threshold:

| host BAR1 | guest BAR1 | |
|---|---|---|
| 256 MiB | `0x90000000` | ok |
| 512 MiB / 1 / 2 GiB | `0x800000000` | ok |
| **4 GiB** | `0x800000000` | **ok — largest working** |
| 8 GiB | `0x8508000000000000` | broken |
| 16 GiB | `0x8508000000000000` | broken |

Working sequence (needs the device released first):

```sh
BDF=0000:01:00.0
echo ""        > /sys/bus/pci/devices/$BDF/driver_override           # unpin
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/unbind
echo 12        > /sys/bus/pci/devices/$BDF/resource1_resize          # 4 GiB
echo vfio-pci  > /sys/bus/pci/devices/$BDF/driver_override
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/bind
```

Two traps that made earlier attempts fail misleadingly:

1. **`driver_override` was pinned to `vfio-pci`.** With it set, the kernel
   immediately re-binds the device, so `unbind` fails and the resize returns
   `EBUSY`/`ENODEV` — masking the real error. Clear it first.
2. **Bit index vs bytes.** Writing byte values (e.g. `1073741824`) decodes to bit
   30 and is correctly rejected with `-EINVAL`. That is not a kernel refusal to
   shrink; the kernel does allow shrinking.

Consequence: the domain now boots with **no `x-no-mmap` and no `x-no-kvm-intx`**.
Those workarounds were only ever compensating for the bad BAR, and are removed.

### Resulting guest state

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10, pin A
   BAR0: 32 bit memory at 0x80000000        [0x83ffffff]
   BAR1: 64 bit prefetchable at 0x800000000 [0x8ffffffff]   4 GiB at 32 GiB
   BAR3: 64 bit prefetchable at 0xf0000000  [0xf1ffffff]
   BAR5: I/O at 0x6000                      [0x607f]
```

No `kvm_set_user_memory_region` or `vfio_container_dma_map` errors. macOS 15.8.1
enumerates the card (`vendor-id de100000`, `device-id 0x2c59`).

### The custom OSX-KVM OVMF is NOT needed

- OSX-KVM's own `macOS-libvirt-Catalina.xml` says so verbatim:
  *"We don't need patched OVMF anymore when using latest OpenCore, stock one is okay"*.
- Tested both with the 4 GiB BAR: **identical result** (`BAR1 = 0x800000000`).
- NixOS's stock OVMF is the better choice: its varstore is correctly paired
  (4 MB code + 528 KB vars), whereas OSX-KVM's pair is mismatched
  (`OVMF_CODE_4M.fd` 3653632 B with `OVMF_VARS*.fd` only 131072 B).
- Their variants exist to pre-set the OVMF preferred resolution
  (`OVMF_VARS-1024x768.fd`, `OVMF_VARS-1920x1080.fd`), per `notes.md`. That is a
  convenience, settable in the OVMF menu, not a requirement.

Kept: `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` + `edk2-i386-vars.fd`.

## RESOLVED — the NullMoth driver now runs

**The single requirement is that BAR1 be 256 MB.** Not a compromise — the value
macOS forces. `gpu-to-vfio` now sets `BAR_IDX_VFIO=8` (256 MB); do not raise it
"for bandwidth".

### Why 256 MB, and why every larger size failed

macOS's `IOPCIFamily` will **not assign** a Resizable BAR larger than that. It
lists BAR1 in the device's `reg` property (it knows the BAR exists) but never in
`assigned-addresses`, so no `IODeviceMemory` descriptor is created. Measured,
identical at 1 GiB and 4 GiB:

```
reg            : ... 14200004 20000000 ...     <- BAR1 present
assigned-addrs : BAR0, BAR3, BAR5, ROM         <- BAR1 absent
nvrm-bars      : bar0@0x10:... bar1@0x1c:...   <- PCI BAR3, not BAR1
```

The NullMoth driver's `readBARs()` fills `bars[]` from the assigned apertures, so
`bars[NV_GPU_BAR_INDEX_FB]` became **PCI BAR3 (32 MB @ 0xf0000000)** — a non-VRAM
window. The driver hands that to the RM as `fb_address`/`fb_size`, and RM's own
assertion fires (captured over the serial console):

```
NVRM: GPU0 kbusVerifyBar2_GB202: MMUTest BAR0 window offset 0x70e000 returned garbage 0x0
NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: Generic memory error
      [NV_ERR_MEMORY_ERROR] (0x00000072) returned from kbusVerifyBar2_HAL(...)
      @ kern_bus_gm107.c:362
NVRM-xnu: rm_init_adapter -> FAILED
NVRM-xnu: auto-go: go(2) -> 0xe00002bc (fPassDone 1)
```

→ no `NVRMDisplay` → no `IOFramebuffer` → no display, no signal.

At **256 MB macOS assigns it**, and the whole chain succeeds:

```
nvrm-bars      : bar0@0x10:0x80000000+0x4000000
                 bar1@0x14:0x90000000+0x10000000     <- PCI BAR1, the real VRAM aperture
                 bar2@0x1c:0x86000000+0x2000000
kbusVerifyBar2 : count 0 (assertion gone)
rm_init_adapter -> OK
PASS 2 REACHED: the adapter is up
4 NVRMDisplay nub(s) published (nvfbheads=4)
auto-go: go(2) -> 0x0 (fPassDone 2)
IOFramebuffer  : 0 -> 5      VRAM,totalsize published (16 GB)      nvrm-autogo = "up"
```

256 MB is NVIDIA's **default non-Resizable-BAR aperture**, which is why macOS
accepts it. Note `placeLargeBar1()` returns false at this size (its guard is
`if (bar1Size < 4 GiB) return false;`), which only affects auto-go timing
(100 s instead of 500 ms) — the BAR does not need the driver to place it,
because macOS assigned it.

### AVENUES CLOSED — do not retry these

* **Move the GPU to a PCIe root port.** macOS defers enumeration behind
  `pcie-root-port` (ACPI hot-plug, `IOPCIHPType 0x21`). Retested with **both**
  `pcie-root-port.hotplug=off` **and**
  `pcie-root-port.x-do-not-expose-native-hotplug-cap=on`; still invisible
  (`10de nodes: 0`). Independently confirmed by the AMD passthrough guide at
  <https://forums.unraid.net/topic/197921-macos-ventura-kvm-amd-radeon-pro-wx-7100-gpu-passthrough-complete-fix-guide/>.
* **Conventional PCI bridge** (`dmi-to-pci-bridge` / `i82801b11-bridge`). macOS
  *does* enumerate the GPU behind it (`pcidebug 1:1:0`) — a genuine improvement
  — but conventional PCI has only a 256-byte config space, so the **Resizable
  BAR capability at extended offset 0x134 is invisible** and the driver bails at
  `"bar1: no Resizable BAR capability"`. Note also that on a PCI bus slot 0 is
  the bridge, so devices need `slot >= 1` (libvirt: *"slot must be >= 1"*).
  Net: the two requirements are mutually exclusive in QEMU — a PCIe port gives
  extended config but macOS won't enumerate it; a conventional bridge is
  enumerated but gives no extended config.
* **`ResizeAppleGpuBars`** (`-1`, `8`, `0`) — no effect whatsoever; the guest
  OpenCore does not touch this passed-through GPU's BAR, so the README's
  `ResizeGpuBars=13` (8 GB) requirement is not met in a VM either way.
* **Patching the driver.** Blocked: the repo publishes **no build path for
  `NVRM.kext`/`NVRMFB.kext`**. `build/accel_build.sh` builds only `NVAccel`;
  `kexts/NVRM/rmcc.py` references a `build-nvrm.sh` that is absent, and needs
  `$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh` plus `libnvkernel.a`
  (a Darwin build of NVIDIA's RM) which are not published. Moot now.

### Capturing the driver's log

The driver logs with `kprintf` (never the unified log; `dmesg` shows 0 NVRM
lines because `debug=0x8` routes it to serial). Working recipe:

1. guest boot-args `+debug=0x8 serial=1`
2. `<serial type='file'><source path='/tmp/macos-serial.log'/></serial>`
3. `tr -d '\0' < /tmp/macos-serial.log | strings > /tmp/serial-clean.txt`

### Still outstanding

1. **BAR sizing is now automatic — no boot service needed.** `gpu-to-vfio` and
   `gpu-to-host` in `packages/gpu-vfio-scripts.nix` program BAR1 (**256 MB on
   vfio**, 16 GiB back on the host), and `gpu-vfio-status` shows the current
   size. Since `vfio-pci.ids=` is commented out (`virtualization.nix:137`), the
   GPU does **not** bind to vfio at boot — `gpu-to-vfio` is the entry point, so
   it is the natural place for the resize and there is nothing to run at boot.
   *Caveat:* if `vfio-pci.ids=10de:2c59,10de:22e9` is ever uncommented for
   boot-time binding, the BAR would come up at the firmware size (16 GiB) and a
   boot-time resize would then be required.
2. **No `IODisplay` yet.** The driver is up and `IOFramebuffer` = 5, but
   `IODisplay`/`IODisplayConnect` are 0, so no head is driving an output and the
   external monitor still gets no signal. This is now a display-output question
   (NVKMS heads / output detection), not a BAR or RM-initialisation one.
3. **SMBIOS is `iMac19,1`**; the driver specifies `iMacPro1,1`.
4. `WhateverGreen.kext` is loaded; the driver README says to remove its NVIDIA
   patches and `agdpmod=pikera`.

## Desktop bring-up — two runtime steps, and only the second is decisive

Once the driver is up (`nvrm-autogo = "up"`, `IOFramebuffer = 5`), macOS still
shows no display. Two steps, tested **one at a time** for attribution:

| step | action | result |
|---|---|---|
| 1 | `sudo sysctl -w debug.nvrmfb_agdc=1` | NVRMAGDC activates (`debug.nvrmfb_agdc_fbmap` goes `never scanned` -> `n=1 [0]id ...`, `cmds` 0 -> 9), but **`IODisplay` stays 0, held for 60 s**. Necessary to map the framebuffer, **not sufficient**. |
| 2 | `sudo launchctl kickstart -k system/com.apple.WindowServer` | WindowServer respawns (pid changes) and within **5 s** `IODisplay` 0 -> 1, `IODisplayConnect` 0 -> 2 -> **this is the step that produces the display** |

Resulting desktop (verified):

```
Sceptre O34:  3440 x 1440 @ 165.00Hz, 24-Bit Color (ARGB8888)
              Main Display: Yes  Mirror: Off  Online: Yes
IOFBCurrentPixelClock = 879720000
```

Both steps are **runtime-only** and vanish on reboot: the sysctl resets, and
WindowServer starts before the driver is ready so it never sees the display.
Something must re-apply them after every boot. Also note the driver only reaches
`"up"` about **100 s after NVRM arms** (`auto-go: go(2) in 100000 ms`, because
`placeLargeBar1()` returns false at a 256 MB BAR1) — so anything that applies
these steps must wait for that, not just for boot.

**Not yet tested:** whether step 1 is a *prerequisite* for step 2. It was active
when step 2 succeeded, but "step 2 with AGDC left off" was never tried, so if
you only want one action at boot, that experiment is still owed.

**Worth reporting upstream:** the driver ships `NVRMAGDC` idle by default
(*"loaded; idle until `sysctl debug.nvrmfb_agdc=1`"*), and relies on a
WindowServer restart to pick the display up. Arguably the driver should arm the
display policy itself and trigger the takeover when the framebuffer is ready,
rather than needing two manual steps — a legitimate bug report independent of
the BAR finding.

## USB passthrough — devices MUST go on an XHCI controller

**Symptom:** a passed-through USB device never appears in macOS, even though
QEMU shows it attached (`info usb` lists it with its real product name).

**Cause:** macOS 15 has **no UHCI driver** (`kmutil showloaded` shows
`AppleUSBEHCI`/`AppleUSBEHCIPCI` but zero UHCI). QEMU routes any full-speed
(12 Mb/s) or low-speed device to a **UHCI companion** of the `ich9-ehci1`
controller, and macOS never drives those ports, so the device is invisible.
Emulated `usb-kbd`/`usb-tablet` work only because they are *high-speed*
(480 Mb/s) and enumerate on the EHCI itself.

**Fix:** add a USB 3 controller and attach hostdevs to it. XHCI has no
companion-controller concept, so full/low-speed devices are handled natively.

```xml
<controller type='usb' index='1' model='qemu-xhci'>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
</controller>

<hostdev mode='subsystem' type='usb' managed='yes'>
  <source><vendor id='0x3151'/><product id='0x4011'/></source>
  <address type='usb' bus='1' port='1'/>      <!-- bus 1 == the XHCI controller index -->
</hostdev>
```

Verified result — macOS then reports a second bus and both devices:

```
USB 3.0 Bus (PCI 1b36:000d)
    G502 HERO Gaming Mouse   046d:c08b  Logitech
    JZ-2.4G keyboard         3151:4011
loaded: com.apple.driver.usb.AppleUSBXHCI + AppleUSBXHCIPCI
```

### The `USBPorts.kext` in the OpenCore ESP does nothing here

`EFI/OC/Kexts/USBPorts.kext` carries personalities matching ACPI names
`EH01`, `UHC1`, `UHC2`, `UHC3` (providers `AppleUSBEHCIPCI`/`AppleUSBUHCIPCI`,
mapping HS11-16 and LS01-06). **This guest's ACPI declares none of those names**
(0 nodes each), so the map matches nothing and is inert. It is not needed for
the XHCI path above. Note it is a *different* map from the one the 1401 app's
own USB section writes (`UTBMap.kext` + `USBToolBox.kext`) — that flow was
never used here, and neither map is required for XHCI passthrough.

## Metal is withheld by design — needs a third runtime gate

**Symptom:** the GPU drives the display and `system_profiler` lists it, but there
is **no `Metal Support` line**, and a compiled test shows zero devices:

```
MTLCopyAllDevices()            -> 0 device(s)
MTLCreateSystemDefaultDevice() -> (nil)
lsof | grep -c NVMTLDriver     -> 0        (plugin installed but never loaded)
```

**Cause — deliberate.** `kexts/NVRM/accel/Info.plist` declares
`MetalPluginName = ../../../Library/GPUBundles/NVMTLDriver`, but
`nvrm-accel.cpp` **removes that property at start**:

```c
fMetalPlugin = mp;
removeProperty("MetalPluginName");
ALOG("MetalPluginName withheld -- nothing will load the Metal plugin until "
     "`sysctl -w debug.nvaccelfb=1` puts it back, and a reboot takes it away again");
```

`onCountGrewLocked()` restores it once the gate is opened. So this is a safety
gate, not a failure.

**Open it:**

```sh
sudo sysctl -w debug.nvaccelfb=1
```

Verified result — `MetalPluginName` reappears (3 nodes), and a **brand new**
process then gets a device (already-running ones will not):

```
MTLCopyAllDevices -> 1 device(s)
  NVIDIA GeForce RTX 5080 Laptop GPU (NVMTL over ... (NVK GB203-B))
system_profiler ... Metal Support: Metal 3
nvrm: b80 LOCAL+mapped memory -> system RAM (b79 placement) (BAR1 256 MB, VRAM 16303 MB, default)
```

**Important:** `nvmtl-allow.txt` still denies `WindowServer`, so **WindowServer
does not get Metal** — which is why the *dynamic* wallpaper still cannot render
and the static-wallpaper fix above remains necessary. Applications, games and
compute can use Metal 3; desktop compositing cannot yet. That matches the file's
own label, `rung 3`, i.e. an incremental enablement stage.

### All three runtime gates, for the boot daemon

| gate | command | why |
|---|---|---|
| AGDC display policy | `sysctl -w debug.nvrmfb_agdc=1` | maps the framebuffer so a display can be created |
| WindowServer re-enumeration | `launchctl kickstart -k system/com.apple.WindowServer` | actually creates the `IODisplay` |
| Metal plugin | `sysctl -w debug.nvaccelfb=1` | restores `MetalPluginName` for new processes |

All three are runtime-only and are lost on reboot. Any boot daemon must wait for
`"nvrm-autogo" = "up"` (≈100 s after NVRM arms) before applying them.

## White desktop / no wallpaper (pre-dates the GPU work)

**Symptom:** the desktop background is plain white. Present since the initial
install, i.e. also with the emulated VMware GPU — not caused by the NVIDIA driver.

**Cause:** the configured wallpaper is the **Dynamic** (animated/video) variant.
macOS 15's stock wallpaper is `/System/Library/Desktop Pictures/.wallpapers/Sequoia Sunrise/`
containing `Sequoia Sunrise.mov` **plus** a `Sequoia Sunrise.heic` still, and the
wallpaper store has `style = 0`, which selects the **dynamic** variant. Rendering
that needs Metal, and **no GPU in this VM reports Metal support**:

* the emulated VMware GPU never had it (hence "since the beginning"), and
* the NullMoth driver still denies WindowServer (see `nvmtl-allow.txt`), so
  `system_profiler SPDisplaysDataType` lists the chipset but **no "Metal Support" line**.
  `IOVideoDecoder` instances = 0, so there is no hardware video decode either.

**Fix:** use a **static** wallpaper. Verified working provider:

```
provider: com.apple.wallpaper.choice.image
files   : [{'relative': 'file:///Users/tianyixia/Pictures/Sequoia%20Still.heic'}]
```

**The catch:** pointing the desktop at a file that *belongs to* a dynamic
provider re-resolves to that provider and stays dynamic. Setting
`/System/Library/Desktop Pictures/Sonoma.heic` produced
`provider = com.apple.wallpaper.choice.sonoma` with `style = 0` — still dynamic.
Copy the image **out** of `/System/Library/Desktop Pictures/` first (e.g. into
`~/Pictures/`); then `com.apple.wallpaper.choice.image` is used and the still renders.

Recipe:

```sh
cp "/System/Library/Desktop Pictures/.wallpapers/Sequoia Sunrise/Sequoia Sunrise.heic" \
   "$HOME/Pictures/Sequoia Still.heic"
sudo launchctl asuser "$(id -u)" osascript -e \
  'tell application "System Events" to set picture of every desktop to "'"$HOME"'/Pictures/Sequoia Still.heic"'
```

`launchctl asuser` is required — the AppleScript has to run inside the logged-in
GUI session, not the SSH session.

**If the driver ever exposes Metal to WindowServer,** the dynamic wallpaper can be
restored by pointing at the `.mov` again (or System Settings > Wallpaper > Dynamic).

## Superseded analysis (kept for the record)

## Passthrough: status and analysis

**Passthrough is currently REMOVED from `macos.xml`** because it crashes the
domain. The GPU's physical BARs, from `lspci -vvs 01:00.0` on the host:

```
Region 0: 64M   (32-bit, non-prefetchable)
Region 1: 16G   (64-bit, prefetchable)     <- the problem
Region 3: 32M   (64-bit, prefetchable)
Region 5: 128B  (I/O)
Expansion ROM: 512K [virtual] [disabled]

Capabilities: [134 v1] Physical Resizable BAR
    BAR 1: current size: 16GB, supported: 64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB
```

### Status: GPU is now ENUMERABLE, but QEMU crashes on the 16 GB BAR

Two separate things were wrong, and only one is fixed.

**Fixed — placement.** macOS defers all PCIe enumeration when it sees ACPI
hot-plug methods, which QEMU emits for every root port. Behind a root port the
card was invisible:

```
Bus 1, device 0, function 0: 10de:2c59
   IRQ 0, pin A
   BAR0/BAR1/BAR5: (not mapped)
```
and no `10de` anywhere in `ioreg`, though `ioreg` did list 30 PCI devices.
On bus 0 the same card comes up properly:

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10
   BAR0: 32 bit memory at 0x80000000  [0x83ffffff]
   BAR1: 64 bit prefetchable at 0x800000000 [0xbffffffff]
   BAR5: I/O at 0x6000 [0x607f]
```

So bus 0 is required, exactly as it was for the NIC. Same root cause.

**Not fixed — QEMU crashes before macOS boots.** With the hostdev present:

```
kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
  start=0x8508000000000000, size=0x400000000: Invalid argument
kvm_set_phys_mem: error registering slot: Invalid argument
shutting down, reason=crashed
```

`0x8508000000000000` is the 64-bit BAR base `0x850800000` reinterpreted as a
64-bit base — an address-placement overflow in QEMU, not a macOS fault.

Ruled out by experiment (both had no effect on the crash):

| Attempt | Result |
|---|---|
| `-cpu ...,phys-bits=40` | QEMU warns `Host physical bits (46) does not match phys-bits property (40)`; crash unchanged |
| `-global q35-pcihost.pci-hole64-size=137438953472` | Confirmed present in QEMU's argv (log line 1348); crash unchanged |

### Next lever: shrink BAR1 — ATTEMPTED, DID NOT WORK

**Result: the shrink was rejected by the kernel.** Recorded so this is not
retried blindly.

`resource1_resize` advertises `0000000000007fc0` — bits 6..14, i.e.
64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB — matching `lspci`. The file is
writable. Writing a new size fails regardless of format:

```
pci 0000:01:00.0: Failed to resize BAR 1: -EINVAL
```

Tested: `1073741824` (1 GiB decimal), `0x40000000` (1 GiB hex), `14` (bit index).
All rejected. The device was correctly unbound first — no `-EBUSY`, which is what
an assigned resource or enabled memory decode would have produced.

Reading `drivers/pci/setup-res.c` (v6.12) shows `-EINVAL` can only come from one
place:

```c
sizes = pci_rebar_get_possible_sizes(dev, resno);
if (!sizes)               return -ENOTSUPP;
if (!(sizes & BIT(size))) return -EINVAL;      /* <- the only -EINVAL */
```

So the size set the kernel validates against does **not** match what the sysfs
mask reports. That is a kernel/hardware disagreement on this device, not a
formatting mistake. (The subsequent `pci_rebar_set_size()` can also fail on
hardware refusal, which would surface as its own error code.)

Net effect: **BAR1 cannot be shrunk from Linux on this kernel (7.2.8).** The card
is unharmed — BAR1 is still `0x6000000000`–`0x63ffffffff` (16 GiB) and it rebinds
to `vfio-pci` cleanly.

### ROOT CAUSE FOUND: the host IOMMU refuses to map the 16 GiB BAR

The crash is **not** guest-side placement. The full log sequence is:

```
vfio_container_dma_map(0x59ebfd150440, 0x382800000000, 0x400000000, 0x7d1240000000) = -22 (Invalid argument)
0000:01:00.0: PCI peer-to-peer transactions on BARs are not supported.
kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
  start=0x8508000000000000, size=0x400000000: Invalid argument
shutting down, reason=crashed
```

Read in order: `size=0x400000000` is **exactly 16 GiB, i.e. BAR1**. QEMU asks the
host IOMMU to map BAR1, the kernel's VFIO **IOMMU** returns `-22 (EINVAL)`, and
that failure then corrupts the memory-region registration. The bogus
`start=0x8508000000000000` is the *symptom*, not the cause. QEMU aborts.

This also explains why every guest-side knob failed: none of them change what the
host IOMMU is asked to map.

### WORKAROUND THAT WORKS: `x-no-mmap=on`

| flag | result |
|---|---|
| *(none)* | **crashes** — `vfio_container_dma_map(...) = -22`, then `kvm_set_user_memory_region ... size=0x400000000 (16 GiB)`, domain aborts |
| `vfio-pci.x-no-kvm-intx=on` (OSX-KVM's own flag) | **crashes identically** |
| **`vfio-pci.x-no-mmap=on`** | **boots.** Domain survives, macOS enumerates the card |

`x-no-mmap` stops QEMU mmapping the BAR, so it traps MMIO in userspace instead
of registering a KVM memory slot for the 16 GiB region — that registration was
the failing path.

Applied as a `-global` (not `-set`, which is processed during early option
parsing before `-device` instances exist, and so cannot reference them by id):

```xml
<qemu:arg value='-global'/>
<qemu:arg value='vfio-pci.x-no-mmap=on'/>
```

The two flags are unrelated: `x-no-mmap` concerns **MMIO/BAR mapping**,
`x-no-kvm-intx` concerns **INTx interrupt injection**. Only the former addresses
this failure.

### Verified state with the workaround

QEMU reports the card on the root bus with real BARs:

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10, pin A
   BAR0: 32 bit memory at 0x80000000          [0x83ffffff]   valid
   BAR1: 64 bit prefetchable at 0x8508000000000000 [0x85080003ffffffff]   BOGUS
   BAR3: 64 bit prefetchable at 0xf0000000    [0xf1ffffff]   valid
   BAR5: I/O at 0x6000                        [0x607f]       valid
```

macOS enumerates it (the driver's third gate now passes):

```
ioreg: 2 x "vendor-id" = <de100000>
Display: Type GPU, Vendor NVIDIA (0x10de), Device ID 0x2c59, Revision 0x00a1
```

Note `bar='off'` appears as a `rombar=0` key on the QEMU device, so something is
still overriding the ROM BAR despite the element being removed from `macos.xml`.

### OPEN ISSUE: BAR1 is at an invalid address

BAR1 — the 16 GiB VRAM window — is presented at `0x8508000000000000`, which is
not a usable address. That is the same value that previously appeared only in
the crash message; with `x-no-mmap` the domain survives but the address is still
wrong. Enumeration succeeding does **not** prove MMIO works: the card is visible
and bound to `IONDRVFramebuffer`, but nothing has yet read GPU registers through
it. Whether the driver can actually drive the card with a bad BAR1 is unknown and
is the next thing to establish.

Also noted: the device is **not** flagged built-in (`"built-in" = <00>`), and
macOS classifies it as `"display"` and attaches it to
`IONDRVFramebuffer/AGPM`.

### Things tried, all ineffective (do not repeat)

| Attempt | Result |
|---|---|
| hostdev behind a root port (bus 0x06) | never enumerated (IRQ 0, BARs unmapped) — that part was real, fixed by bus 0 |
| `-cpu ...,phys-bits=40` | QEMU warns host is 46-bit; crash identical |
| `-global q35-pcihost.pci-hole64-size=137438953472` | confirmed in QEMU argv; crash identical |
| `-cpu ...,phys-bits=46,+pdpe1gb` | Proxmox's documented precondition for BARs > 16 GB; **crash identical** |
| shrink BAR1 to 1 GiB via `resource1_resize` | kernel returns `-EINVAL`; BAR cannot be shrunk |
| removing `<rom bar='off'/>` | no effect |

The Proxmox precondition work (bug #7711) is real and worth knowing — EDK2 caps
MMIO at `2^(phys-bits-3)`, so `phys-bits` governs BAR space and not just RAM —
but it is **not** our blocker. We fail earlier, in the host IOMMU.

### CONCLUSION: the GPU enumerates but macOS assigns it no BARs

Measured in the guest with `mmio-probe.py` and `ioreg`. The GPU node has **no
memory resources at all**, while its own audio function on the same card has
them:

| node | `IODeviceMemory` | `assigned-addresses` |
|---|---|---|
| `S20@40000` — GPU `10de:2c59` | **0 (none)** | **absent** |
| `S21@4,1` — audio `10de:22e9` | present, `address=2242461696 length=16384` | present |

Identity is correct (`vendor-id de100000`, `device-id 592c0000`,
`class-code 00000300` = VGA, `built-in 00`), and the node carries
`IOPCIResourced = Yes` with the firmware `reg` — but macOS created **no assigned
addresses and no memory objects for any GPU BAR**. No `IONDRVFramebuffer`/AGPM is
created for it either.

Consequence: **`install.sh`'s `ioreg` gate passes while the card is unusable.**
That gate only greps for `vendor-id = <de100000>`. Enumeration does not imply a
usable aperture, and this is the one thing to remember from all of the above: the
gate is satisfied by a card whose memory windows cannot be mapped.

`mmio-probe.py`'s userland map attempt returns `0xe00002c2`
(`kIOReturnUnsupported`) — expected without an entitlement, and it tells us
nothing either way (an `IOPCIDevice` has no user client).

Note on tooling: `/usr/bin/python3` is an Xcode CLT stub, so the probe needs a
real Python and root. `ioreg` alone can read `IODeviceMemory` (it prints decimal
`address`/`length`), which needs neither. The probe's `reg` decoder is **wrong** —
it reports every entry as `config addr=0x0` — so do not trust its BAR decode; the
`IODeviceMemory` section and `ioreg` are the reliable evidence.

### What this means, and the remaining options

The host IOMMU cannot map a 16 GiB BAR for this device. Options, best first:

1. **Disable Resizable BAR in the host BIOS.** The card then exposes a small
   default BAR (typically 256 MB) instead of 16 GiB and the IOMMU map is trivial.
   This is the direct fix for the actual failure, and it matches NullMoth's own
   bare-metal recipe (`ResizeGpuBars=13` = an **8 GB** BAR).
2. **Try a different QEMU version.** 11.1.1 is very new; a regression in vfio
   IOMMU mapping or the `p2p` handling is plausible.
3. **Stop.** The driver remains unproven on this card (developed on an RTX 5060;
   ours is mobile Blackwell), so the remaining work may not pay off.

`shrink-gpu-bar.sh` implements the safe unbind/resize/rebind sequence and is
reusable if the kernel behaviour changes.

## Re-enabling passthrough

Restore these two elements in `macos.xml`, inside `<devices>`:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0' multifunction='on'/>
</hostdev>
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x1'/>
</hostdev>
```

`managed='yes'`, no `<rom>` element, guest bus **0x00** (not a root port), and
`multifunction='on'` on function 0 so the audio function is seen. Then confirm
from the host that QEMU survives and the card shows `IRQ`/mapped BARs, and from
the guest that `ioreg` lists `10de`.

## Recommended order

**Phase 1 and Phase 2 are deliberately separate.** Do not arm the driver
(`nvfb=1 nvaccel=1`) in the same boot that first brings the GPU through: if that
boot fails you cannot tell whether passthrough or the driver caused it. The
hostdevs are already in `macos.xml`; the OpenCore settings are not yet applied.

### Phase 1 — verify passthrough alone (current state)

Boot the domain as it is. The guest should come up on the virtual GPU exactly as
before, now with an unknown NVIDIA display device attached. Confirm:

```sh
ioreg -r -c IOPCIDevice -d 1 | grep -i 'vendor-id.*de100000'   # the card is visible
system_profiler SPDisplaysDataType | head -30                   # listed, likely "no kext loaded"
```

If macOS still boots cleanly and the card is visible, passthrough works. If the
boot hangs, the problem is passthrough, not the driver — and you still have the
virtual GPU plus SSH to recover.

### Phase 2 — arm and install

1. **Apply the guest-side settings** (Route A or B above), then reboot and confirm:
   ```sh
   nvram boot-args
   csrutil status          # expect: disabled
   ```
2. **Only then run `install.sh`.** Gate 3 passes now.
3. Reboot, then verify:
   ```sh
   kmutil showloaded --list-only | grep nullmoth      # expect 4
   system_profiler SPDisplaysDataType | head -20      # expect GeForce + Metal
   ```
4. **Arm the Metal gate** — the accelerator withholds `MetalPluginName` until:
   ```sh
   sudo sysctl -w debug.nvaccelfb=1
   ```
   and `/Library/GPUBundles/nvmtl-allow.txt` is a process allow-list defaulting
   to deny (test apps must be listed, or be named `mtlprobe`/`nvmtltest`/
   `nvmtlrender`).

## Host power note

The GPU is currently bound to `vfio-pci` at boot, so the host is not using it and
passing it through costs nothing. If you would rather leave the card powered down
when not in use, `gpu-off` / `gpu-on` / `gpu-power-status` manage that. The
accelerator's own README notes the driver expects the card **powered on**, so run
`gpu-on` (or leave the vfio-pci default binding) before starting the domain.

## Recovery levers — have these ready BEFORE installing

- **`-nvoff`** — NVRM honours it and leaves the card alone. Add it to boot-args
  to disarm the driver without uninstalling:
  ```sh
  sudo nvram boot-args="... -nvoff"
  ```
- **`install.sh` is safe-ish by construction**: it test-builds the collection
  before writing anything, and writes a numbered backup. If macOS will not boot,
  `/Library/NullMoth/backup-*` plus `uninstall.sh <dir>` is the way back — but
  that needs a bootable system, so keep SSH access working.
- **Keep the virtual GPU.** Do not remove `<video>` from the domain: it is the
  console of last resort if the NVIDIA driver wedges the display, and it is how
  you keep SSH reachable.

## Honest risk assessment

1. **Untested card.** Developed on an RTX 5060 (`2d05`). Ours is `10de:2c59`,
   RTX 5080 Max-Q, mobile Blackwell GB203M. Its NVRM maps the GB20X family and
   the package ships `gsp_ga10x.bin`/`ucodes_ga10x.bin`, so there is a plausible
   path, but mobile Blackwell is outside the tested set. The README says so.
2. **Firmware must be present** at `/Users/Shared/nvfw/nvidia/610.57.04/`.
   `install.sh` copies it, but if the tarball's `pkgroot` layout differs the
   copy will be wrong — verify the four `.bin` files exist after install.
3. **Unsigned kexts need Secure Boot off in the guest.** Ours is already off
   (libvirt picked the non-secure OVMF loader). Do not re-enable.
4. **No display will light up from the passed-through card** unless something is
   plugged into its outputs: the internal panel is wired to the Intel Arc iGPU.
   `nvfbheads=4` may create heads, but that is untested here.
