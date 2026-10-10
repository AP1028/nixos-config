# NVIDIA driver on the G16 — state, mechanism, and next steps

**Last updated:** 2026-10-09, after the `ResizeGpuBars = -1` test boot.
**Read this first.** It supersedes `NVIDIA-DRIVER-INSTALL.md` for anything about
the display failure.

---

## 1. Where we are, in one screen

```
ACHIEVED   BAR1 is 8 GB. NVRM/NVAccel/NVRMFB/NVRMAGDC load and run.
           The driver takes head 0 and performs a real modeset.
BROKEN     WindowServer crash-loops. macOS enumerates zero displays.
           CoreDisplay: "Setting offline display 0x00000000 main" -> abort
FIXED      Aperture fallback (was the cause of "no modeset") - see section 3.
IN FLIGHT  nvfbheads=1 retest, applied, not yet booted.
```

**Machine is always reachable over SSH** — every failure so far is display-layer
only.

## 2. Versions

```
macOS         15.8.1 (24H32)
GPU           RTX 5080 Laptop, 10de:2c59, Metal: Supported
Panel         2560x1600 @ 240 Hz (OLED)
Driver tested 1.0.9 (1401 Mac 1.0.13) and 1.1.0 (1401 Mac 1.1.1)
              BOTH FAIL IDENTICALLY - this is not a version regression
App installed 1.0.13; note v1.0.13/1.0.14/1.0.15 carry a boot-file
              preservation defect (fixed in 1.0.16). We never used the
              USB-to-internal promotion path, so nothing was damaged.
```

**Driver 1.0.9 and 1.0.10 are the same binaries** — the 1.0.15 notes say all 47
protected files are unchanged. **1.0.10 only adds an installer load-command
check.** No reason to move between them for behaviour.

## 3. THE KEY FINDING: the aperture, and why `ResizeGpuBars` broke it

With `ResizeGpuBars = 13` the driver could not get a CPU-writable scanout
aperture, so it fell back to publishing the GOP's console surface:

```
NEITHER vidmem NOR sysmem gave a CPU-writable scanout aperture
  -- refusing to light a head at memory WindowServer cannot reach
aperture retry round N: BAR1 not CPU-writable yet -- waiting 5 s
applyMode: skipped (console aperture mode -- the GOP drives this panel)
console info: base 0x6000000000 rowBytes 8192 1920x1080 depth 32
boot pair: display 0x200 keeps the firmware's mode 2560x1600 @240000
```

**The console was 1920x1080 while the panel is 2560x1600** — and with no modeset
published, CoreDisplay saw an offline display and aborted.

**With `ResizeGpuBars = -1` the whole path succeeds:**

```
VIDMEM ACCEPTED -- aperture 0x3fc00200000
head probe retired (answered: we own head 0)
enableController's modeset owns the head
fbmodes: published IOFBScalerInfo (up+down, max 3840x2160) + IOFBTiming
```

**That is the visible white flash** — the driver taking the head and doing a real
modeset.

**The 8 GB BAR survives anyway, placed by the driver instead of the firmware:**

```
bar1: Resizable BAR capability @0x134 says BAR1 = 8192 MB
bar1: PLACED — BAR1 8192 MB live at 0x3fc00000000
nvrm-bars: bar1@0x14:0x3f800000000+0x400000000
```

**So the original goal is met either way — and `ResizeGpuBars = -1` is the
better arrangement**, because the firmware resize is what starved the aperture.

## 4. The remaining failure, and it is narrower now

```
NVAccel: NVRMFramebuffer published -- display machine framebuffer count = 0
WindowServer (CoreDisplay):
  Created FB 2 of 2
  Setting offline display 0x00000000 main in AddCGXDisplayDeviceToDeviceList
    0  CoreDisplay::AddMainOfflineBreadcrumb + 317
    1  CoreDisplay::Framebuffer::Framebuffer(unsigned int, unsigned long long, ...) + 3601
    2  CoreDisplay::GPU::GPU(__GPUWranglerGPU*, dispatch_queue_s*) + 744
    3  invocation function for block in CoreDisplay::GPUController::GPUController() + 2634
    7  WS::Displays::CoreDisplayManager::initialize() + 43
```

**Two framebuffers are created and CoreDisplay makes the offline one main.**
The crash moved out of mode enumeration and into framebuffer construction —
i.e. the modeset half now works and the problem is which framebuffer gets
chosen.

Also present, probably incidental:

```
NVRM: _sysCreateOs: RM Access Sys Cap creation failed: 0x56
NVAccel: NVRM-framebuffer published -- display machine framebuffer count = 0 (in ...)
PV-SENTINEL REFUSED: slid _pmap_verify_free text != BootKC 24G830 bytes (diagnostic)
```

## 5. Switches the driver exposes

Extracted from the binaries themselves, not guessed:

```
SWITCH                STATE        MEANING
-nvfbsurvey           SET          framebuffer survey
nvfb=1                SET          start the framebuffer (absent = boot-loop guard)
nvaccel=1             SET          start the accelerator
nvfbheads=N           1 (testing)  display heads (4 default; 1 and 4 both tried)
-nvkmsnosmooth        SET          recommended in the driver's own docs
-nvrmnogo             untried      disable the auto-go thread (the 500 ms go(2))
-nvrmnobootscreen     untried      skip the boot-screen handoff entirely
-nvrmnoflip           untried      no flip path
nvhwvbl=0             untried      timer instead of hardware VBL
nvhud=1               untried      on-screen probe grid + HUD, fires t+45 s
nvfbsample=1          untried      pixel sampler every 10 s
nvrmfb_flip_lean      untried      leaner flip path
-nvoff                -            disable the driver
```

**`-nvrmnobootscreen` is the most promising untried one** — `nvrm-boot-hold` has
read `display armed` through every attempt, which is the boot-screen handoff
never completing.

**Diagnostics that put pixels on the panel** (useful because SSH can't see the
screen): `nvhud=1` draws a probe grid and HUD after 45 s; `nvfbsample=1` samples
pixels every 10 s. **If either appears, the panel is being driven and the fault
is purely in what CoreDisplay is told.**

## 6. Config state right now

```
UEFI -> Quirks -> ResizeGpuBars          -1      (changed from 13 - this fixed the aperture)
Booter -> Quirks -> ResizeAppleGpuBars   -1
boot-args                                 -v debug=0x100 keepsyms=1 -vi2c-force-polling
                                          nvfb=1 nvaccel=1 nvfbheads=1 -nvkmsnosmooth
                                          amfi_get_out_of_my_way=0x1 amfi=0x80 -nvfbsurvey
csr-active-config                         0x0A43
Kernel -> Block                           com.apple.iokit.IONDRVSupport (Exclude)
Misc -> Security -> SecureBootModel       Disabled
Misc -> Security -> ExposeSensitiveData   7       (boot-path; needed by 1401)
Kernel -> Quirks -> CustomSMBIOSGuid      True    (with UpdateSMBIOSMode = Custom)
Misc -> Debug -> Target                   usb 79 / internal 15
```

**Both ESPs identical except `Misc -> Debug -> Target`.** USB was last on
`nvfbheads=4` — resync when it is next connected.

## 7. Recovery

```
Boot picker -> 1401: Remove NVIDIA driver     (on the internal ESP; works without USB)
sudo ./uninstall.sh /Library/NullMoth/backup-20261009-050851
```

**Full backups:** `efi-backups/efi-{usb,internal}-20261009-041949.tar.gz`
**Version control:** `efi-vcs/` — every config change is a commit with its reasoning.

## 8. Next steps, in order

1. **Boot `nvfbheads=1`** with the aperture fix in place (applied, untested).
2. **`-nvrmnobootscreen`** if that fails — boot-hold has never left `armed`.
3. **`nvhud=1`** to get visible evidence of whether the panel is driven.
4. **`-nvrmnogo`** — the auto-go thread is what arms the display; without it the
   driver may stay out of the handoff entirely.
5. **Report upstream.** The bug report is narrow and strong: the modeset works,
   the framebuffer publishes modes, and CoreDisplay is handed an offline
   display 0. Include the aperture findings — that `ResizeGpuBars = 13` starves
   the CPU-writable aperture is a concrete, reproducible interaction between a
   documented OpenCore setting and this driver.

## 9. What is genuinely established

- The driver loads, runs, and drives the GPU; `Metal: Supported`
- **BAR1 reaches 8 GB**, by firmware resize or by the driver's own placement
- The aperture/console-aperture fallback is the reason no mode was ever
  published with `ResizeGpuBars = 13`
- With the aperture fixed, the driver takes head 0 and modesets
- **Both driver versions 1.0.9 and 1.1.0 fail identically** — not a regression
- The failure is now: CoreDisplay chooses an offline framebuffer as main
