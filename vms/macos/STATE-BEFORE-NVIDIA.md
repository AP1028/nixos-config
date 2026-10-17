# State before the NVIDIA driver install

Snapshot taken 2026-10-09, immediately before starting the NullMoth NVIDIA
driver work. Everything here is verified.

---

## 1. Hardware

```
ASUS ROG Zephyrus G16 GU605CW          BIOS GU605CW.311 11/20/2025
Intel Core Ultra 9 285H (Arrow Lake-H)  16 CPUs enumerated
NVIDIA RTX 5080 Laptop GPU              MUX must stay on the dGPU for macOS display
Intel Arrow Lake CNVi WiFi  8086:7740   NOT driveable - no macOS driver exists
Realtek ALC1308 (SoundWire)             NOT driveable - no macOS audio transport
Intel Bluetooth 8087:0037 "BlazarU"     NOT driveable - kext lacks this chip
```

## 2. What works

```
macOS 15.8.1 (24H32)   boots to userland and the desktop
Secure Boot            ENABLED and working - boot.efi hash enrolled in db
Display                works (MUX on dGPU)
USB Ethernet           works (the network path)
Volume / mute keys     3 Fn keys on the Consumer HID page (should work natively)
```

## 3. What does not work

```
Trackpad    device not exposed by ACPI - see section 5
WiFi        no driver exists for 8086:7740 - unsolvable
Audio       SoundWire codec - unsolvable internally; USB/HDMI audio are the routes
Bluetooth   support gap, not a wall - see BLUETOOTH-BLAZARU-PORT.md
Fn keys     10 of 13 need a custom kext - see HARDWARE-FINDINGS-WIFI-FNKEYS.md
```

## 4. Boot chain and Secure Boot

```
firmware -> rEFInd -> OpenCore -> boot.efi (Preboot APFS volume)
```

Secure Boot is satisfied by a **SHA-256 hash entry for `boot.efi` in `db`**
(enrolled via `efi-updatevar`, value `72a72cee...`), which requires:

```
Booter -> Quirks -> FixupAppleEfiImages = False
Misc -> Security -> SecureBootModel     = Disabled
```

**After any macOS update `boot.efi` changes and the hash must be re-enrolled.**
The procedure and its three gotchas are in this document set.

## 5. Trackpad — current state and the next step

**The kext is not the problem.** It loads, its constructors register, and its
`kmod_info` is byte-comparable to the Xcode-built original. VoodooI2C drives the
I2C controller (`VoodooI2CControllerDriver` attached and active).

**The problem is that the touchpad ACPI devices never get created.** All 24 of
them (`TPD0`/`TPL1` across six I2C controllers) are gated by:

```c
If (((TPDT != Zero) && (I2CN & One)))
    Return (0x0F)
Return (Zero)
```

where `I2CN` is populated in `_INI` from `SDS0`, an EC-backed value that reads
zero on macOS. Patched so far:

- **Done:** the 24 `_STA` fallbacks changed `Return (Zero)` -> `Return (Ones)`
  (AML bytes `A4 00` -> `A4 FF`, same length, 25 bytes total with checksum).
  Verified surgical; table still loads with identical namespace structure.
- **Still failing:** the devices remain absent.

**Next step:** the whole block sits inside `If ((PCHA == Zero))`, and `PCHA` is
referenced 22 times but **declared nowhere** — it likely comes from an ASUS SSDT.
macOS's ACPICA (20160930) also performs a two-pass namespace load that skips `If`
bodies in pass 1. The next thing to try is an SSDT defining `PCHA`, or patching
the outer `If` conditions.

**Rollback:** `EFI/OC/ACPI/DSDT.aml.pre-statpatch` on both ESPs.

## 6. EFI layout — both ESPs are in sync

```
usb       volume "1401"      the debugging vehicle
internal  volume "NO NAME"   disk1s1 - the normal boot path
```

**The only intended difference is `Misc -> Debug -> Target`:**

```
usb:       79   file logging ON
internal:  15   file logging OFF (protects the ESP)
```

Kext order is Dortania's canonical: `VoodooI2CServices -> VoodooGPIO ->
VoodooI2C -> VoodooI2CHID`. The `VoodooInput` entries are disabled (not in the
canonical config).

## 7. Backups and version control

```
efi-backups/efi-usb-20261009-041949.tar.gz        13,287,340 bytes   538 files
efi-backups/efi-internal-20261009-041949.tar.gz  207,377,291 bytes   462 files
efi-vcs/                                          git repo, 39 files, commit 4b54438
```

The internal tarball is large only because that ESP also holds `EFI/nixos`
(190 MB) and `EFI/Linux` — the NixOS bootloader, not the macOS setup.

## 8. OpenCore logging — a known limitation

`opencore-*.txt` files on the ESP are **262,144 bytes of spaces** on successful
boots. They contain OpenCore's messages *only when something fails*, and
boot.efi's output only when `AppleDebug` is on. One captured failure was:

```
OC: Prelinked injection VoodooI2CHID.kext () - Invalid Parameter
```

Do not expect these logs to be useful on a normal boot.

## 9. NVIDIA driver — where to get it

**The local checkout is `v1.0.0`, which is outdated.**

```
Latest:              nvidia-macos-driver v1.1.1   (2026-10-08)
Paired Windows:      1401 v1.1.0
Downloaded to:       ~/Downloads/1401-v1.1.0/
  1401-Windows-1.1.0.zip    289,335,722  sha 6f762916...  VERIFIED
  1401-Mac-1.1.1.dmg          2,632,672  sha 8cbf4c1c...  VERIFIED
  1401-Mac-1.1.1.zip          2,275,472  sha 8ebf3def...  VERIFIED
```

**Release notes worth knowing:**

- **Known issue (v1.1.0):** with two displays connected, changing one display's
  refresh rate or resolution can make the other flash or go blank until restart.
  Fix planned for 1.2.
- **Scope:** installs on **macOS 15 only**. RTX 5090, macOS 26, iGPU/dGPU
  switching, DRM and full Firefox/Blender/Geekbench behaviour are **not
  qualified**.
- Windows bundle contains the matching Mac companion and driver payload.

**Prerequisites the driver requires** (from its own documentation):

```
boot-args            nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth
                     amfi_get_out_of_my_way=0x1 amfi=0x80
csr-active-config    <430A0000>
SecureBootModel      Disabled
UEFI -> Quirks       ResizeGpuBars = 13        (8 GB BAR1 - the original goal)
Booter -> Quirks     ResizeAppleGpuBars = -1
Kernel -> Block      com.apple.iokit.IONDRVSupport
BIOS                 Above 4G on, CSM off
```

Current config has the **installer** values (`ResizeAppleGpuBars = 0`,
`ResizeGpuBars = -1`); the 1401 app switches them.

**This is the invasive step.** Install from the USB with the recovery entry
available: boot picker -> `1401: Remove NVIDIA driver` -> `NullMothSafe.efi`.

---

## Outcome

The driver was installed on 2026-10-09. **BAR1 is 8 GB — the goal was met.**
The desktop does not come up because CoreDisplay cannot obtain a display mode.

**See `NVIDIA-DRIVER-INSTALL.md`** for the full result, the evidence, the
phantom-head lead, and the recovery procedure.
