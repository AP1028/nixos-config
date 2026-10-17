# NVIDIA driver install — result and current state

**Installed:** 1401 Mac 1.1.1 with driver payload `nullmoth-nvidia-1.1.0.tar.gz`
**Date:** 2026-10-09
**Host:** ASUS ROG Zephyrus G16 GU605CW, macOS 15.8.1 (24H32)

---

## 1. The primary goal is achieved: BAR1 is 8 GB

The reason this whole exercise started was:

> *"I need a bar larger than 192/256, ideally 16G or 8G"*

**That is done, and it is directly observable from the running kernel:**

```
$ ioreg -l -w0 | grep -o '"nvrm-bars" = "[^"]*"'
"nvrm-bars" = "bar0@0x10:0x90000000+0x4000000
               bar1@0x14:0x3fc00000000+0x200000000
               bar2@0x1c:0x3fe00000000+0x2000000"
```

`0x200000000` is **8 GiB** of BAR1. `UEFI -> Quirks -> ResizeGpuBars = 13` did
what it is documented to do, and NVRM moved BAR1 away from the boot screen as
`docs/HOW-IT-WORKS.md` describes.

## 2. The driver loads and the whole stack comes up

```
$ kmutil showloaded | grep nullmoth
  126  com.nullmoth.NVRMFB     0x16ff2
  142  com.nullmoth.NVRM       0xd7cffc
  144  com.nullmoth.NVAccel    0x11ff5
  159  com.nullmoth.NVRMAGDC   0x2ffa

$ ioreg -p IOService -w0 | grep -A3 NVRM
  NVRM          registered, matched, active, busy 0 (4284 ms)
   +-o NVRMDisplay   registered, matched, active
   |   +-o NVRMFramebuffer (NVRMNVDAFramebuffer)  registered, matched, active
   |       +-o AGPM

$ ioreg -l -w0 | grep '"nvrm-'
  "nvrm-autogo"       = "up"
  "nvrm-boot-hold"    = "display armed"
  "nvrm-boot-raster"  = "head0 240.000Hz"
  "nvrm-display"      = "heads 0x1 accel 4 agdc 1 k5 1 iop 1"
  "nvrm-flip"         = "on"
```

The GPU is an RTX 5080 Laptop GPU, device id `0x2c59`, reported as
**Metal: Supported**.

## 3. What is broken: WindowServer cannot get a display mode

**Symptom:** the screen shows text, then clears, repeatedly. Verbose boot output
stays on screen and never hands off to the desktop.

**The machine is fully up and reachable over SSH** — this is a display-layer
failure only.

```
$ log show --last 6m --predicate 'process == "WindowServer"' | grep CoreDisplay
[WARN]  Creating FB 1 of 1
[WARN]  IOFBSetDisplayModeAndDepth: Setting mode 0x0 with depth 0x0 on displayID: 0x0
[WARN]  IOFBSetDisplayModeAndDepth: Failed to obtain mode info from IOFBGetDisplayModeInformation()
[ERROR] Setting offline display 0x00000000 main in AddCGXDisplayDeviceToDeviceList
        0  CoreDisplay::AddMainOfflineBreadcrumb(bool, char const*, ...) + 317
        3  WS::Displays::CoreDisplayManager::initialize() + 43
```

```
$ pgrep WindowServer          # nothing
$ ls /Library/Logs/DiagnosticReports/WindowServer-*.ips | wc -l
15                            # and rising, one per restart attempt
```

**Reading of it:** the framebuffer registers a display object and the driver arms
a boot raster, but it never publishes a *current mode*. CoreDisplay asks for mode
information, gets none, decides the display is offline, and aborts. It never
reaches a point where it could drive a display.

`system_profiler SPDisplaysDataType` prints an empty `Graphics/Displays:` section
— **macOS currently enumerates zero displays.**

## 4. The one concrete lead: phantom display heads

```
$ ioreg -p IOService -w0 | grep "class NVRMDisplay"
  NVRMDisplay  id 0x1000005d3  busy 0 (477 ms)   <- the real panel, did work
  NVRMDisplay  id 0x1000005fa  busy 0 (0 ms)     <- never used
  NVRMDisplay  id 0x1000005fb  busy 0 (0 ms)     <- never used
  NVRMDisplay  id 0x1000005fc  busy 0 (0 ms)     <- never used

"nvrm-display" = "heads 0x1"      <- the driver reports ONE head
```

**`nvfbheads=4` created four display objects on a machine with one internal
panel, and only the first ever did anything.** The three inert objects are the
narrowest explanation for mode enumeration failing.

**Change made and committed:**

```
boot-args:  nvfbheads=4  ->  nvfbheads=1
            (efi-vcs b1c3b5f, applied to the internal ESP)
```

`boot-args` is present in `NVRAM -> Delete`, so the value is rewritten each boot
rather than inherited.

**Result of this change is not yet known** — it needs a reboot to test.

## 5. The external monitor test did not reach the driver

Plugging in a USB-C monitor produced:

```
USB 2.0 BILLBOARD
  Product ID: 0x0103
  Vendor ID:   0x2109  (VIA Labs, Inc.)
```

**A "BILLBOARD" device is what a USB-C hub presents when its DisplayPort
alt-mode negotiation fails.** The monitor never established a link, so this was
never a test of the driver's external output — it is a hub/cable problem.

**To test external output properly, connect a display without that hub** — a
direct HDMI cable, or USB-C to DisplayPort straight into the machine. The
machine also carries a GenesysLogic USB3.1 hub with an ASIX AX88179B Ethernet
adapter on it, so the hub is doing other work; it is specifically its DP path
that failed.

## 6. The install itself was correct

Everything the installer was supposed to do, verified afterwards:

```
/Library/Extensions
  NVRM.kext      com.nullmoth.NVRM      16,746,048 bytes
  NVAccel.kext   com.nullmoth.NVAccel      233,664 bytes
  NVRMFB.kext    com.nullmoth.NVRMFB       268,576 bytes
  NVRMAGDC.kext  com.nullmoth.NVRMAGDC      50,872 bytes

/Library/KernelCollections/AuxiliaryKernelExtensions.kc
  18,563,072 bytes, rebuilt at install time, 14 nullmoth references
  (the aux KC is what macOS 15 boots third-party kexts from)

config
  ResizeGpuBars 13, ResizeAppleGpuBars -1
  csr-active-config 0x0A43
  Kernel -> Block  com.apple.iokit.IONDRVSupport (Exclude)
  SecureBootModel Disabled
  OC/Tools/NullMothSafe.efi present
  /Library/LaunchDaemons/com.nullmoth.recover.plist
  /Library/LaunchAgents/com.nullmoth.crashcheck.plist
```

**The `IONDRVSupport` block did its job** — `IONDRVFramebuffer` sits at 0
instances, so the firmware framebuffer is not holding display index 0.

## 7. Recovery, if it comes to that

**Boot picker -> `1401: Remove NVIDIA driver`.** This exists on the internal ESP
(and should be synced to the USB when it is next connected). It adds `-nvoff` and
sets `nullmoth-remove=1`, which the removal LaunchDaemon acts on.

**Nothing else needs undoing.** The BAR resize is a firmware setting applied by
OpenCore; reverting `ResizeGpuBars` to `-1` restores the old behaviour.

## 8. Notes for whoever picks this up

**The driver's own release notes already flag this area as its weak point:**

> *A display request the GPU rejects (for example an unsupported cursor size) now
> fails only that request. Previously one rejected request could stop presentation
> and block every later resolution and refresh change until restart.*
>
> *Known issue: With two displays connected, changing the refresh rate or
> resolution of one display can make the other display flash or go blank until
> the Mac is restarted. A fix is planned for 1.2.*

**The panel is 240 Hz** (a G16 OLED), and the driver armed exactly that:
`nvrm-boot-raster = "head0 240.000Hz"`. The raster is not the mismatch — the
missing piece is the mode publication to CoreDisplay.

**Things worth trying next, in order:**

1. **Boot with `nvfbheads=1`** (already applied, untested) — removes the three
   inert display objects.
2. **Connect a display directly, no hub** — tests the external output path
   independently of the internal panel.
3. **Capture the driver's own view during a failed handoff** — the NVRMFB log
   already shows it answering `getPixelInformation` for a dozen resolutions, so
   the mode table exists; the question is why it is not offered as a current mode.
4. **Report upstream** with the `nvrm-bars` / `nvrm-boot-hold` / CoreDisplay
   evidence above — the BAR half works perfectly, which makes the display half a
   much narrower bug report than "it does not work".

## 9. What has not been tested

- Whether the 8 GB BAR improves real workloads (no desktop yet to measure on)
- Any Metal / compute path — `Metal: Supported` is reported but nothing has run
- External display output at all
- Behaviour across a refresh-rate change, which the release notes flag
