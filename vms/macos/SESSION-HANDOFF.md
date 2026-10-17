# SESSION HANDOFF — NVIDIA driver on the ASUS ROG Zephyrus G16 GU605CW

**Purpose of this file:** a complete context dump so a fresh session can resume
without re-deriving anything. Read this top to bottom before touching the
machine. Everything here was verified unless explicitly marked as a hypothesis.

**Written:** 2026-10-09, during the NVIDIA display debugging.

---

# PART 0 — THE GOAL AND WHERE IT STANDS

## The original request

> *"I need a bar larger than 192/256, ideally 16G or 8G"*

The NullMoth NVIDIA driver for macOS requires `ResizeGpuBars = 13` (8 GB BAR1).

## Status

```
✅ ACHIEVED   BAR1 reaches 8 GB, verified from the running kernel
✅ ACHIEVED   All four driver kexts load and run; Metal: Supported
✅ ACHIEVED   The driver takes head 0 and performs a real modeset
✅ FIXED      The aperture starvation caused by ResizeGpuBars = 13 (section 4)
❌ BROKEN     WindowServer crash-loops; macOS enumerates ZERO displays
⏳ IN FLIGHT  nvhud=1 + nvfbsample=1 applied, awaiting a boot to see if pixels
              appear on the panel
```

**The machine is always reachable over SSH.** Every failure so far is
display-layer only — the OS boots and runs fine.

---

# PART 1 — MACHINES AND ACCESS

```
asusg16   the target laptop
          macOS 15.8.1 (24H32) at 192.168.1.109  (the SSH address used throughout)
          Linux (NixOS)        at 192.168.1.250
          Boots macOS via OpenCore; MUX must stay on the dGPU

macbook   the control machine, 192.168.1.50
          where this session's working files and documentation live
          /home/tianyixia/nixos-config/vms/macos/  <- all docs
          /home/tianyixia/Projects/macos/nvidia-macos-driver/  <- driver source clone (v1.0.0)
```

**SSH from the macbook:**
```bash
ssh tianyixia@192.168.1.109
```
**`sudo -n` works on the laptop** (passwordless for the commands used here).

**Disk enumeration is NOT stable across reboots.** `disk0`/`disk1` have swapped
repeatedly. **Always resolve ESPs by partition UUID or volume name, never by
disk number.** The two ESPs:

```
internal ESP   volume "NO NAME"   uuid 6A72E4BD-561E-4A78-9D04-B4A32B84CC86
               holds the real OpenCore, the boot picker entry, the driver config
USB stick      volume "1401"      the debugging/recovery vehicle
               SanDisk 123 GB, FAT32 partition; was NOT connected for the last
               several reboots so it is BEHIND on config changes
Windows ESP    volume "SYSTEM"    do not touch
```

**Mounting needs root:** `sudo diskutil mount diskXsY`. Unprivileged
`diskutil mount` fails and that failure is silent in 1401's scripts — this
caused a long false trail (see Part 5).

---

# PART 2 — HARDWARE FACTS

```
CPU        Intel Core Ultra 9 285H (Arrow Lake-H), 16 CPUs
GPU        NVIDIA RTX 5080 Laptop, PCI 10de:2c59, at RP12/GFX0
Panel      2560x1600 @ 240 Hz OLED (the G16's internal display)
iGPU       Arrow Lake integrated, not usable for macOS display here
WiFi       8086:7740 Arrow Lake CNVi  -- IMPOSSIBLE, no driver exists
Audio      Realtek ALC1308 on SoundWire -- IMPOSSIBLE internally
Bluetooth  8087:0037 "BlazarU" -- support gap, not a wall
Trackpad   I2C HID on I2C0/I2C3; see Part 8
```

**MUX position matters** — macOS only drives the display with the MUX on the
dGPU.

---

# PART 3 — THE DRIVER: WHAT IT IS AND HOW IT INSTALLS

## Releases and the version confusion

**The app and the driver package have separate version numbers.** This matters:

```
1401 Mac app      driver package it ships
v1.0.13           1.0.9
v1.0.14           1.0.9
v1.0.15           1.0.10     <- marked prerelease, carries the boot-file defect
v1.0.16           1.0.10     <- the fix for that defect
v1.0.17/1.0.18    1.0.11
v1.1.0 / v1.1.1   1.1.0
```

**CRITICAL:** driver 1.0.9 and 1.0.10 are **the same binaries**. From the
v1.0.15 release notes: *"All 47 protected GPU, kernel, firmware, compiler and
removal files, plus both runtime links, remain unchanged from package 1.0.9."*
**1.0.10 only adds an installer load-command compatibility check.**

**Both 1.0.9 and 1.1.0 were installed and booted on this machine. THEY FAIL
IDENTICALLY.** This is not a version regression.

## ⚠️ The boot-file preservation defect

**1401 Mac v1.0.13, v1.0.14 and v1.0.15 carry a defect.** From the v1.0.15 notes:

> *"Do not use the USB-to-internal OpenCore promotion path in this version or
> earlier versions. A preservation defect can remove existing Windows and vendor
> boot files from the active destination EFI partition; **a backup alone does not
> keep Windows bootable.**"*

**Fixed in v1.0.16** — *"Automatic copying onto another EFI partition is now
disabled."*

**We are NOT affected** — every install targeted the **startup** partition,
discovered via `booted_part()` or given explicitly with `--config`. Nothing
touched the Windows ESP. **Do not use the USB-to-internal promotion path.**

## Install invocation (verified working)

The app is a front-end; `nullmoth-setup.sh` does the preflight and calls
`nullmoth-install.sh --payload <dir>`.

```bash
SHA=9dbfdb1b1359e2ef4166a46905ee195774b0b4ba20be083a8111ef550b1e5789  # 1.0.9 payload
PKG="$HOME/Downloads/1401-v1.0.13/nullmoth-nvidia-1.0.9.tar.gz"
APP="/Volumes/1401 Mac 1.0.13/NullMoth/1401.app"     # note: inside a NullMoth/ folder
R="$APP/Contents/Resources"
chmod +x "$R"/*.sh        # scp/zip can drop the exec bit; setup.sh checks for it

# dry run first
sudo bash "$R/nullmoth-setup.sh" --dry \
  --tool "$R/NullMothSafe.efi" --app "$APP/Contents/MacOS/1401" \
  --pkg "$PKG" --sha "$SHA"

# real install (drop --dry)
```

**Gotchas hit repeatedly:**
- The DMG mounts the app at `<vol>/NullMoth/1401.app`, **not** `<vol>/1401.app`.
- `nullmoth-setup.sh` requires `--tool` (path to `NullMothSafe.efi`) or it stops
  with *"the boot-picker tool is missing from the app"*.
- It requires the exec bit on `nullmoth-install.sh`.
- It requires root (`id -u = 0`).

**What an install does** (from the dry run): adds boot-args
`nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80`,
sets `ResizeGpuBars 13` / `ResizeAppleGpuBars -1`, adds
`Kernel -> Block: com.apple.iokit.IONDRVSupport (Exclude)`, sets
`csr-active-config 0x0A43`, adds the `1401: Remove NVIDIA driver` boot-picker
entry, and installs four kexts.

**Verified install locations:**
```
/Library/Extensions/NVRM.kext        com.nullmoth.NVRM
/Library/Extensions/NVAccel.kext     com.nullmoth.NVAccel
/Library/Extensions/NVRMFB.kext      com.nullmoth.NVRMFB
/Library/Extensions/NVRMAGDC.kext    com.nullmoth.NVRMAGDC
/Library/KernelCollections/AuxiliaryKernelExtensions.kc   <- macOS 15 boots from here
```
The aux KC must contain the kexts — check with
`strings -a <kc> | grep -c com.nullmoth` (expect 14) or by timestamp.

**Install record + undo:**
```
/Library/NullMoth/state                       (root-only readable)
/Library/NullMoth/backup-20261009-050851      (driver backup)
sudo ./uninstall.sh /Library/NullMoth/backup-20261009-050851
```

---

# PART 4 — THE CENTRAL DISCOVERY: APERTURE STARVATION

**This is the single most important finding of the session.**

## With `ResizeGpuBars = 13` (the shipped default)

The driver cannot obtain a CPU-writable scanout aperture, so it keeps the GOP's
console surface and **skips the modeset**:

```
NEITHER vidmem NOR sysmem gave a CPU-writable scanout aperture
  -- refusing to light a head at memory WindowServer cannot reach
aperture retry round N: BAR1 not CPU-writable yet -- waiting 5 s
applyMode: skipped (console aperture mode -- the GOP drives this panel)
CONSOLE APERTURE MODE: publishing BAR1+0 (0x%llx) pitch %u %ux%u -- no modeset

console info: base 0x6000000000 rowBytes 8192 1920x1080 depth 32
boot pair: display 0x200 keeps the firmware's mode 2560x1600 @240000
console probe: using NVKMS vtFb 0x6000000000 (8847360 B)
```

**Note the mismatch: the console aperture is 1920x1080 (8,847,360 bytes) while
the panel's real mode is 2560x1600 @240 Hz.** No modeset is published, so
CoreDisplay sees an offline display and aborts.

## With `ResizeGpuBars = -1`

**The whole path succeeds:**

```
VIDMEM ACCEPTED -- aperture 0x3fc00200000
verifyAperture(kernelPhys) 0x3fc00200000: +0x1000=c0de1111 ...
head probe retired (answered: we own head 0)
reflip keep-alive NOT armed: enableController's modeset owns the head
fbmodes: published IOFBScalerInfo (up+down, max 3840x2160) + IOFBTiming
```

**This is the visible white flash the user reported** — the driver taking the
head and doing a real modeset. Confirmed by the driver's own string:

```
"boot screen: head 0 painted the %ux%u boot image (pitch %u) centred on %ux%u"
```

## And the 8 GB BAR survives anyway

**The driver places a large BAR1 itself, so `ResizeGpuBars = -1` does NOT lose
the goal:**

```
bar1: Resizable BAR capability @0x134 says BAR1 = 8192 MB
bar1: placing BAR1 8192 MB @0x3fc00000000, BAR3 32 MB @0x3fe00000000
bar1: PLACED — BAR1 8192 MB live at 0x3fc00000000
nvrm-bars = "bar0@0x10:0x90000000+0x4000000
             bar1@0x14:0x3f800000000+0x400000000
             bar2@0x1c:0x3fc00000000+0x2000000"
```

**Conclusion: `ResizeGpuBars = -1` is the better arrangement on this machine.**
The firmware resize is what starves the aperture; the driver's own placement
achieves the same 8 GB without breaking the display path.

---

# PART 5 — WHY 1401 REFUSED TO RUN (three separate causes, all fixed)

This was a long false trail. **Recording it because the same symptoms will
recur.** 1401 v1.1.0's release notes: *"Require startup-partition ownership
evidence before internal EFI operations; remove the timestamp-only fallback."*
That check needs three things, all of which were broken:

### 5a. `boot-path` NVRAM variable never written

1401 reads `4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path` to identify the
startup ESP. OpenCore only writes it when `Misc -> Security ->
ExposeSensitiveData` has **bit `0x01`** set. The config had the OpenCore
failsafe **`0x6`** (bits 0x02|0x04 only).

**Fix:** `ExposeSensitiveData = 7` on both ESPs. (From OpenCore's
`Configuration.tex`: `0x01 --- Expose the printable booter path as a UEFI
variable.`)

### 5b. The SMBIOS spoof was never applying

`hw.model` reported `ROG Zephyrus G16 GU605CW_GU605CW` (the firmware's real
value) while the config declared `MacBookPro16,2`. **1401 matches `hw.model`
against the config's SMBIOS model and rejected the config.**

**Root cause:** `UpdateSMBIOSMode = Custom` writes the SMBIOS to
`gOcCustomSmbios(3)TableGuid` and **requires** `Kernel -> Quirks ->
CustomSMBIOSGuid = True` to patch `AppleSmbios.kext`/`AppleACPIPlatform.kext` to
read that GUID. The quirk was **False**, so macOS read the firmware's tables.

**Fix:** `CustomSMBIOSGuid = True` (kept `Custom` mode — it prevents the
firmware overwriting SMBIOS at `ExitBootServices`). **Verified working:**

```
hw.model        = MacBookPro16,2
board-id        = Mac-5F9802EFE386AA28
product-name    = MacBookPro16,2
manufacturer    = Acidanthera
```

### 5c. Unmounted ESPs are silently skipped

`mount_efi()` in 1401's script calls a plain `diskutil mount` with
`>/dev/null 2>&1`. Without privilege or a pre-existing mount, every candidate is
silently skipped, and the user gets *"no OpenCore config on any connected disk"*.

**Diagnostic trap:** mounting the ESPs by hand while investigating makes 1401
appear to work, so the fault looks intermittent. **It is not.**

**Fix/workaround:** `sudo diskutil mount diskXsY` before launching 1401.

**Full documentation of all three: `EFI-BOOT-PATH-1401.md`.**

---

# PART 6 — CURRENT FAILURE: WindowServer ABORTS

## The mechanism

```
NVAccel: NVRMFramebuffer published -- display machine framebuffer count = 0

WindowServer (CoreDisplay):
  [WARN]  Created FB 2 of 2
  [ERROR] Setting offline display 0x00000000 main in AddCGXDisplayDeviceToDeviceList
            0  CoreDisplay::AddMainOfflineBreadcrumb(bool, char const*, ...) + 317
            1  CoreDisplay::Framebuffer::Framebuffer(unsigned int, unsigned long long,
                                                      unsigned int, unsigned long long) + 3601
            2  CoreDisplay::GPU::GPU(__GPUWranglerGPU*, dispatch_queue_s*) + 744
            3  invocation function for block in CoreDisplay::GPUController::GPUController() + 2634
            7  WS::Displays::CoreDisplayManager::initialize() + 43

  exception: EXC_CRASH, SIGABRT ("Abort trap: 6")
```

**ANSWER TO "WHY DOES WINDOWSERVER CRASH":** CoreDisplay is told to make
display `0x0` the *main* display. Display `0x0` is **offline** — it has no
current mode. `AddMainOfflineBreadcrumb()` is the defensive path for
"this should be impossible"; it records a breadcrumb and then **aborts**.
WindowServer dies by SIGABRT, launchd restarts it, the same thing happens
immediately — hence the crash loop (25+ crashes per boot, one every few seconds).

**The abort is not a bug in WindowServer.** It is CoreDisplay refusing to
continue with an inconsistent display list. The real fault is upstream: the
framebuffer never gives display `0x0` a mode.

Also seen (probably incidental):
```
Error: No property 'FB_Triage', or property isn't a string.
Error: Can't get value for key 'Triage'.
NVRM: _sysCreateOs: RM Access Sys Cap creation failed: 0x56
PV-SENTINEL REFUSED: slid _pmap_verify_free text != BootKC 24G830 bytes (diagnostic)
```

## Supporting evidence, current boot

```
"nvrm-display"   = "heads 0x1 accel 4 agdc 1 k5 1 iop 1"
"nvrm-boot-hold" = "display armed"          <- has NEVER left "armed"
"nvrm-boot-raster" = "head0 239.997Hz"
"nvrm-flip"      = "on"
"nvrm-autogo"    = "up"
DISPLAYS macOS ENUMERATES: 0
```

The panel mode is detected correctly:
```
boot raster: head 0 vline wraps 60 moves 106285 max 1775 -> 239.999 Hz MEASURED
             | armed raster 2640x1776 pclk 1125275000 Hz -> 240.000 Hz
boot pair: display 0x200 head 0 connector 0x2 mode 2560x1600 @240000 pitch 10240
```
Display enumeration:
```
dpy 0/4 0x100: connected 0 edid 0 B   connector 0x0 headMask 0x0
dpy 1/4 0x200: connected 1 edid 256 B connector 0x2 headMask 0xf
dpy 2/4 0x400: connected 1 edid 384 B connector 0x3 headMask 0xf
dpy 3/4 0x800: connected 0 edid 0 B   connector 0x0 headMask 0x0
ENUMERATED: 2 connected display(s) of 4 handle(s), 4 heads available
index 0 -> display 0x200 connector 0x2 headMask 0xf -> head 0 (taken now 0x1)
```

---

# PART 7 — DRIVER SWITCHES (extracted from the binaries, not guessed)

```
SWITCH                 CURRENT     MEANING / EVIDENCE
nvfb=1                 SET         start the framebuffer; absent = "boot-loop guard"
nvaccel=1              SET         start the accelerator
nvfbheads=N            1           display heads; 1 and 4 both tried
-nvkmsnosmooth         SET         recommended in the driver's own docs
-nvfbsurvey            SET         framebuffer survey
nvhud=1                SET         probe grid + HUD ON SCREEN at t+45s  <- VISIBLE
nvfbsample=1           SET         pixel sampler every 10s              <- VISIBLE
-nvrmnogo              untried     "auto-go OFF (-nvrmnogo): idle until `nvrmctl go <pass>`"
-nvrmnobootscreen      untried     "boot screen: snapshot OFF" (NOT the handoff)
-nvrmnoflip            untried     no flip path
nvhwvbl=0              untried     "OFF (boot-arg nvhwvbl=0) - the timer is the VBL"
nvrmfb_flip_lean      untried     leaner flip path
-nvoff                 -           disable the driver
```

**Only NVRMFB parses boot-args directly.** Confirmed from strings:
`boot-arg nvfb=1`, `boot-arg nvfbsample=1`, `boot-arg nvhud=1`,
`boot-arg nvhwvbl=0`.

**`-nvrmnobootscreen` is LESS useful than it sounds** — it disables the boot
screen *snapshot*, not the handoff. **`-nvrmnogo` is the more promising
untried one**, because it gives manual control: the driver idles until
`nvrmctl go <pass>`.

**Why `nvhud=1` matters:** it separates a *display-path* failure from a
*reporting* failure. If pixels appear, the panel is driven and only
CoreDisplay's view is wrong.

---

# PART 8 — UNRELATED WORK FROM EARLIER IN THE SESSION (context only)

## Trackpad — stopped, documented, resumable

**The kext is not the problem.** `VoodooI2CHID` loads, its constructors
register, its `kmod_info` is field-identical to the Xcode-built original, and
`VoodooI2C` drives the I2C controller.

**The touchpad ACPI devices never get created.** All 24 (`TPD0`/`TPL1` across six
I2C controllers) are gated by:

```c
If (((TPDT != Zero) && (I2CN & One)))
    Return (0x0F)
Return (Zero)
```

where `I2CN = SDS0` (an EC value) is set in `_INI` and reads zero on macOS.

**Patched so far:** the 24 `_STA` fallbacks changed `Return (Zero)` →
`Return (Ones)` (AML `A4 00` → `A4 FF`, same length, 25 bytes with checksum,
verified surgical, table still loads with identical namespace structure).
**Devices still absent.**

**Next step:** the whole block sits inside `If ((PCHA == Zero))`, and `PCHA` is
referenced 22× but **declared nowhere** — likely from an ASUS SSDT. macOS's
ACPICA (20160930) also does a two-pass namespace load that skips `If` bodies in
pass 1. Try an SSDT defining `PCHA`, or patch the outer `If`.

**Rollback:** `EFI/OC/ACPI/DSDT.aml.pre-statpatch` on both ESPs.

**Docs:** `VOODOOI2CHID-PR75-MERGE.md`, `STATE-BEFORE-NVIDIA.md`.

## Impossible / documented elsewhere

```
WiFi       8086:7740 has zero references in itlwm's device table. Not solvable.
Audio      ALC1308 on SoundWire. Use USB or HDMI audio.
Bluetooth  8087:0037 "BlazarU" absent from IntelBluetoothFirmware. See
           BLUETOOTH-BLAZARU-PORT.md
Fn keys    Only 3 of 13 work (Consumer page). See HARDWARE-FINDINGS-WIFI-FNKEYS.md
```

## Secure Boot (working, don't break it)

Satisfied by a **SHA-256 hash of `boot.efi` in `db`** (`72a72cee...`), which
requires `Booter -> Quirks -> FixupAppleEfiImages = False` and
`Misc -> Security -> SecureBootModel = Disabled`. **After any macOS update
`boot.efi` changes and the hash must be re-enrolled.** Do not touch
`Reset To Setup Mode` — it would clear PK/KEK/db and break NixOS Secure Boot.

---

# PART 9 — CURRENT CONFIG STATE

## Internal ESP (`/Volumes/NO NAME`) — the one that boots

```
UEFI -> Quirks -> ResizeGpuBars          -1     <- CHANGED from 13; this fixed the aperture
Booter -> Quirks -> ResizeAppleGpuBars   -1
boot-args                                 -v debug=0x100 keepsyms=1 -vi2c-force-polling
                                          nvfb=1 nvaccel=1 nvfbheads=1 -nvkmsnosmooth
                                          amfi_get_out_of_my_way=0x1 amfi=0x80
                                          -nvfbsurvey nvhud=1 nvfbsample=1
csr-active-config                         0x0A43
Kernel -> Block                           com.apple.iokit.IONDRVSupport (Exclude)
Misc -> Security -> SecureBootModel       Disabled
Misc -> Security -> ExposeSensitiveData   7      (boot-path; 1401 needs it)
Kernel -> Quirks -> CustomSMBIOSGuid      True   (required by UpdateSMBIOSMode = Custom)
Misc -> Debug -> Target                   15     (no file logging - quiet)
```

**USB ESP (`/Volumes/1401`):** last known to be on `nvfbheads=4`,
`ResizeGpuBars = 13`, `ExposeSensitiveData = 7`, `CustomSMBIOSGuid = True`, and
**does not have `nvhud`/`nvfbsample`/`-nvfbsurvey`/`ResizeGpuBars -1`.**
**Sync it when next connected.** The only intended difference between the ESPs
is `Misc -> Debug -> Target` (usb 79 / internal 15).

## Version control — `efi-vcs/` (git)

```
cd /home/tianyixia/nixos-config/vms/macos/efi-vcs
usb/OC/       internal/OC/       README.md       KEXTS-manifest.txt
```
**Every config change made this session is a commit with its reasoning in the
message.** Read `git log` to see the whole chain. Key commits:

```
48d0b0f  Consolidate the display investigation into one state document
7929bf1  TEST: ResizeGpuBars -1 (no bar resize) + -nvfbsurvey
8b9558d  Document the NVIDIA driver install result
0e66ace  ExposeSensitiveData 6 -> 7
8a349fb  Enable CustomSMBIOSGuid
4b54438  EFI snapshot (canonical kext order, Xcode plist, _STA-patched DSDT)
```

## Backups

```
efi-backups/efi-usb-20261009-041949.tar.gz        13,287,340   538 files
efi-backups/efi-internal-20261009-041949.tar.gz  207,377,291   462 files
EFI/OC/ACPI/DSDT.aml.pre-statpatch                (on both ESPs)
EFI/OC/config.plist.nullmoth-20261009-050847      (on the internal ESP)
/Library/NullMoth/backup-20261009-050851          (driver backup)
```

## Documentation set in `/home/tianyixia/nixos-config/vms/macos/`

```
NVIDIA-DISPLAY-STATE.md        <- START HERE for the display work
NVIDIA-DRIVER-INSTALL.md       <- the install result and evidence
EFI-BOOT-PATH-1401.md          <- the three 1401 refusal causes
STATE-BEFORE-NVIDIA.md         <- the machine state before the driver
VOODOOI2CHID-PR75-MERGE.md     <- the trackpad kext build recipe
HARDWARE-FINDINGS-WIFI-FNKEYS.md
BLUETOOTH-BLAZARU-PORT.md
```

---

# PART 10 — RECOVERY (if the driver ever stops macOS starting)

```
Boot picker -> 1401: Remove NVIDIA driver      (on the internal ESP; no USB needed)
```
That adds `-nvoff` and sets `nullmoth-remove=1`; the LaunchDaemon acts on it.
It is the `NullMothSafe.efi` entry added by the installer.

```
sudo ./uninstall.sh /Library/NullMoth/backup-20261009-050851   # full driver removal
```

**Reverting the display-side changes** means setting `ResizeGpuBars` back to
`13`, and removing `-nvfbsurvey nvhud=1 nvfbsample=1` from boot-args. **Reverting
the driver entirely** means the uninstaller above.

**The machine always boots to a usable SSH session even when the display is
dead**, so nothing here is unrecoverable.

---

# PART 11 — EXACT NEXT STEPS

## Immediate (applied, awaiting a boot)

`nhud=1` and `nvfbsample=1` are set. **On the next boot, watch the panel:**

- **Pixels appear within ~45 s** → the display path works and only CoreDisplay's
  view is wrong. Focus on `IOFBGetDisplayModeInformation` and why display `0x0`
  is offline.
- **Nothing appears** → the display path is dead. Go to `-nvrmnogo`.

## Then, in order

1. **`-nvrmnogo`** — *"auto-go OFF: idle until `nvrmctl go <pass>`"*. The auto-go
   thread is what arms the display; without it the driver stays out of the
   handoff and can be driven manually. **This is the most promising untried
   switch.**
2. **`-nvrmnoflip`** and/or **`nvhwvbl=0`** — flip path and VBL timing.
3. **Force a fixed mode.** `setDetailedTimings` accepts installed timings;
   `NVKMS validateDisplayMode refused the raster (not an EDID mode)` suggests the
   armed raster may not match an EDID mode exactly (239.999 measured vs 240.000
   armed). **Worth investigating whether an exact-EDID mode changes the
   outcome.**
4. **Report upstream.** The bug report is strong and narrow — see Part 12.

## Things NOT to do

- **Do not use 1401's USB-to-internal OpenCore promotion path** (Part 3).
- **Do not change `disk` numbers** — resolve ESPs by UUID.
- **Do not touch `Reset To Setup Mode`** — breaks NixOS Secure Boot.
- **Do not reinstall the driver** — 1.0.9 and 1.1.0 are identical in behaviour
  and 1.0.9/1.0.10 are the same binaries.

---

# PART 12 — THE UPSTREAM BUG REPORT (draft)

**Title:** RTX 5080 Laptop on Arrow Lake-H: framebuffer never publishes a
display mode; CoreDisplay aborts with display 0x0 offline

**Half the system works, which is what makes this a good report:**

```
WORKS   BAR1 = 8 GB (nvrm-bars: bar1@0x14:0x3f800000000+0x400000000)
        NVRM, NVAccel, NVRMFB, NVRMAGDC all load
        NVRM -> NVRMDisplay -> NVRMNVDAFramebuffer chain complete
        Panel detected: boot raster 239.999 Hz MEASURED, armed 240.000 Hz
        Modeset performed, IOFBScalerInfo + IOFBTiming published
        Metal: Supported
FAILS   macOS enumerates ZERO displays
        CoreDisplay aborts in AddMainOfflineBreadcrumb
        WindowServer crash-loops (25+ crashes/boot)
```

**Two findings worth their attention:**

**1. `ResizeGpuBars = 13` starves the CPU-writable aperture.** With it:
```
NEITHER vidmem NOR sysmem gave a CPU-writable scanout aperture
  -- refusing to light a head at memory WindowServer cannot reach
applyMode: skipped (console aperture mode -- the GOP drives this panel)
```
With `ResizeGpuBars = -1` the aperture is accepted
(`VIDMEM ACCEPTED -- aperture 0x3fc00200000`) and the modeset happens, **while
the driver still places an 8 GB BAR1 itself.** So the documented OpenCore
setting actively breaks the display path on this machine, and is unnecessary.

**2. Even with the aperture fixed, display `0x0` stays offline.**
```
nvrm-boot-hold = "display armed"        (never leaves "armed")
Created FB 2 of 2
Setting offline display 0x00000000 main -> AddMainOfflineBreadcrumb -> abort
```

**Tried with no effect:** `nvfbheads` 4 and 1; driver packages 1.0.9 and 1.1.0
(identical binaries for the protected files).

**Not yet tried, listed for completeness:** `-nvrmnogo`, `-nvrmnoflip`,
`nvhwvbl=0`, exact-EDID timing registration.

**Hardware:** ASUS ROG Zephyrus G16 GU605CW, Core Ultra 9 285H (Arrow Lake-H),
RTX 5080 Laptop (10de:2c59), 2560x1600 @240 Hz internal panel, macOS 15.8.1,
OpenCore REL-109.
