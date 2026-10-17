# Bluetooth on the GU605CW — port task for Intel "BlazarU" (8087:0037)

**Status: NOT WORKING on macOS. Fully diagnosed. Bounded port task, not a dead end.**

This document is self-contained: everything needed to do the work later, without
re-probing anything.

---

## 1. Summary

The Bluetooth hardware is **healthy** — Linux drives it completely. macOS has no
driver for this specific chip because **Intel shipped it after
`IntelBluetoothFirmware`'s last update**. The chip is a codename ("BlazarU") that
appears nowhere in the kext.

Unlike the WiFi (`8086:7740`, CNVi, no driver exists) and the audio codec
(`ALC1308`, SoundWire, no macOS transport driver), **Bluetooth is reachable**: it is
an ordinary USB device and the driver that would serve it already exists and works
for twelve sibling chips.

---

## 2. What macOS sees

`system_profiler SPBluetoothDataType` shows a **placeholder stub**, which is what
macOS publishes when it finds no supported Bluetooth hardware:

```
Chipset:  BCM_4350C2        <- Apple's default, not the real chip
Transport: UART             <- the real device is USB
Vendor ID: 0x004C (Apple)   <- Apple's own ID
Address: NULL   State: Off   Firmware Version: v0 c0
```

But the device **is** enumerated on USB:

```
Bluetooth HCI
    Vendor ID:  0x8087  (Intel Corporation)
    Product ID: 0x0037
```

So the hardware is present and visible; nothing claims it.

---

## 3. What Linux sees (the working reference)

```
hci0:  Type: Primary  Bus: USB
       BD Address: C8:95:CE:50:47:99     <- real MAC assigned
       UP RUNNING PSCAN
       RX 25258 bytes  TX 1001458 bytes  commands: 4049
```

```
Bluetooth: hci0: Device revision is 0
Bluetooth: hci0: Secure boot is enabled
Bluetooth: hci0: OTP lock is disabled
Bluetooth: hci0: API lock is enabled
Bluetooth: hci0: Bootloader timestamp 2022.18 buildtype 1 build 16362
Bluetooth: hci0: Found device firmware: intel/ibt-0093-0291.sfi
Bluetooth: hci0: Boot Address: 0x100800
Bluetooth: hci0: Firmware Version: 35-29.26
Bluetooth: hci0: Firmware loaded in 2117469 usecs
Bluetooth: hci0: Device booted in 50809 usecs
Bluetooth: hci0: Found Intel DDC parameters: intel/ibt-0093-0291.ddc
Bluetooth: hci0: Applying Intel DDC parameters completed
Bluetooth: hci0: Firmware SHA1: 0x239ed887
Bluetooth: hci0: Fseq status: Success (0x00)
```

**`4049 HCI commands` with `Fseq status: Success` means the firmware loaded and the
chip is fully operational.** Nothing is wrong with the hardware.

---

## 4. The chip identity (decoded via btmon)

**Reproduction.** The modern Intel Read Version is `OGF 0x3f, OCF 0x0005` — *not* the
legacy `0x0001`, which is why the obvious command fails with "Broken pipe". The
reliable method is to capture HCI traffic across a re-init:

```bash
sudo rfkill unblock bluetooth
sudo btmon -w /tmp/bt.snoop >/dev/null 2>&1 &
sleep 2
sudo modprobe -r btusb; sleep 2; sudo modprobe btusb
sleep 10
sudo pkill -x btmon
btmon -r /tmp/bt.snoop | grep -A20 "Intel Read Version"
```

Result:

```
Intel Read Version (0x3f|0x0005)  Status: Success (0x00)
    CNVi TOP(16):  0x00080930              -> 0x0093
    CNVr TOP(17):  0x02001910              -> 0x0291
    CNVi BT(18):   0x001d3700 - BlazarU(0x1d)     <- CHIP CODENAME
    CNVr BT(19):   0x00312200
    CNVr OTP(21):  0x0432
    Device Rev ID(22): 0x0000
    USB VID(23):   0x8087
    USB PID(24):   0x0037
    Image Type(28): Firmware(0x03)
    HCI Revision(37): 0x4723
    LMP SubVersion(38): 0x4723
    OTP Lock(42):  Enabled(1)
    API Lock(43):  Enabled(1)
```

**Key cross-check:** the firmware filename `ibt-0093-0291` is exactly
`CNVi TOP` + `CNVr TOP`. This confirms the naming convention the kext uses.

**The chip is "BlazarU", type `0x1d`** — newer than any codename in the kext.

---

## 5. The firmware (already extracted)

Extracted from this machine's `linux-firmware` and **committed alongside this
document** in `bt-firmware/`:

```
bt-firmware/ibt-0093-0291.sfi    980840 bytes
bt-firmware/ibt-0093-0291.ddc         4 bytes
```

(A copy was also at `/tmp/btfw/` during the session, but `/tmp` does not survive a
reboot - use the committed copy.)

Source on the laptop:

```
/nix/store/xa0ka2cg61x6v5r865h46qh2vbawaivm-linux-firmware-20260810-zstd/lib/firmware/intel/ibt-0093-0291.sfi.zst
/nix/store/xa0ka2cg61x6v5r865h46qh2vbawaivm-linux-firmware-20260810-zstd/lib/firmware/intel/ibt-0093-0291.ddc.zst
```

Extraction (they are zstd-compressed):

```bash
zstd -d /nix/store/.../ibt-0093-0291.sfi.zst -o ibt-0093-0291.sfi
zstd -d /nix/store/.../ibt-0093-0291.ddc.zst -o ibt-0093-0291.ddc
```

**The chip has secure boot enabled (OTP + API lock), so it only accepts signed
firmware.** The `.sfi` blob is signed; this must not be altered.

---

## 6. Why the kext does not work

Checked against **both master and the v2.4.0 release**:

### 6.1 No product-ID match

`IntelBluetoothFirmware.kext/Contents/Info.plist` covers:

```
0x0025 0x0026 0x0029 0x0032 0x0033 0x0035 0x0036 [0x0038] 0x07dc 0x0a2a 0x0a2b 0x0aa7 0x0aaa
```

**`0x0037` is absent** — from the firmware kext, from `IntelBluetoothInjector`, and
from `IntelBTPatcher`. It appears **zero times** in the source
(`BtIntelFw.cpp`, `BtIntel.cpp`, `IntelBluetoothFirmware.cpp`, `FwData.h`), and no
GitHub issue or PR mentions it.

Note the gap: `0x0035`, `0x0036` and `0x0038` are all supported.

### 6.2 The hardware-variant switch rejects it

`IntelBluetoothOpsGen3.cpp` (~line 137):

```c
switch (verPtr->hw_variant) {
    case 0x0b:  /* SfP */   case 0x0c:  /* WsP */
    case 0x11:  /* JfP */   case 0x12:  /* ThP */
    case 0x13:  /* HrP */   case 0x14:  /* CcP */
        if (!bootloaderSetup(verPtr)) return false;
        break;
    default:
        XYLog("Unsupported Intel hw variant (%u)\n", verPtr->hw_variant);
        return false;
}
```

These are legacy codenames. **BlazarU (`0x1d`) is not among them.**

### 6.3 The firmware is not bundled

The kext ships `ibt-0040-*`, `ibt-0180-*`, `ibt-0291-0291`, `ibt-1040-*`,
`ibt-11-5`, `ibt-12-16`, `ibt-17-*`, `ibt-18-*`, `ibt-19-*`, `ibt-20-*` in its `fw/`
directory — **but not `ibt-0093-0291`**.

---

## 7. What the port involves

The kext already contains most of the machinery, which is why this is bounded:

| Piece | Status |
|---|---|
| Firmware filename construction | **already correct** — `getFirmwareName()` builds `ibt-%04x-%04x.%s` from the same fields Linux uses |
| ECDSA secure-boot send path | **already present** — `ecdsaHeaderSecureSend()` (Gen3, ~line 442) |
| Firmware download | `downloadFirmwareData(ver, fwData, bootParams, hwVariant, sbeType)` |
| DDC parameter application | already implemented |
| Firmware resource loading | `fw/` directory pattern already established |

### The changes

1. **Add `0x0037` to the product lists** in `IntelBluetoothFirmware.kext/Contents/Info.plist`
   (and `IntelBluetoothInjector` / `IntelBTPatcher` if they gate on it).
2. **Add `ibt-0093-0291.sfi` and `.ddc`** to the kext's `fw/` resources.
3. **Add a `hw_variant` case for BlazarU (`0x1d`)** in `IntelBluetoothOpsGen3.cpp`,
   alongside the existing cases, calling `bootloaderSetup()`.
   - *First verify what `verPtr->hw_variant` actually holds for this chip* — the TLV
     dump above reports CNVi/CNVr TOP and CNVi BT, and the kext's `hw_variant` field
     may correspond to the CNVi BT type (`0x1d`) or to a different TLV. Confirm before
     guessing; a wrong case could send the chip down the wrong firmware path.
4. **Boot address** — Linux reports `0x100800`; check `bootloaderSetup()` derives it
   correctly for this variant rather than assuming a legacy default.
5. **Build, install to both ESPs, test.**

### Reference implementation

**Linux's `drivers/bluetooth/btintel.c` is the working reference for exactly this
chip** — it drove it successfully on this machine. Port the logic rather than
inventing it.

---

## 8. Build and install

The kext build toolchain on this machine is proven (see
`VOODOOI2CHID-PR75-MERGE.md`): Command Line Tools + `clang` + `MacKernelSDK`, no
Xcode needed. Relevant traps from that document apply here too:

- `-nostdinc` with **MacKernelSDK first** in the include order
- The kext binary must be `MH_KEXT_BUNDLE`, and must contain a real
  **`_kmod_info`** symbol (link `MacKernelSDK/Library/x86_64/libkmod.a` and provide
  `kmod_info`) — **OpenCore silently skips kexts without it**
- `Info.plist` may contain unsubstituted Xcode variables

Install target — **both** boot paths:

```
USB:       /Volumes/1401/EFI/OC/Kexts/
internal:  /Volumes/NO NAME/EFI/OC/Kexts/     (sudo diskutil mount disk0s1)
```

Config entries go after Lilu and VirtualSMC. `BlueToolFixup` (from
`BrcmPatchRAM`) is also required on macOS 12+ for the Bluetooth stack to initialise
at all — 1401's own optional-kext list names all three:
`IntelBluetoothFirmware`, `IntelBTPatcher`, `BlueToolFixup`.

---

## 9. Risks and unknowns

- **Secure boot on the chip.** OTP and API locks are set, so the firmware must be
  correctly signed *and* sent through the right secure-boot path. The kext has ECDSA
  support, but whether it matches this chip's engine type is unverified.
- **The exact `hw_variant` value** — resolve this before editing the switch (see 7.3).
- **A wrong variant case could mis-route firmware**, which at worst means the chip
  fails to initialise (recoverable) rather than being damaged.
- **No reports exist.** No issue, PR or forum post mentions `0x0037`, BlazarU, or
  Bluetooth on Arrow Lake. This would be the first attempt.
- Keep the existing EFI backed up. Removal is deleting the kext + config entries.

---

## 10. Verdict

```
Not working today                        ✓ confirmed
Not a dead end (unlike WiFi and audio)   ✓ hardware healthy, driver exists
Effort                                   a few hours, mostly build/test cycles
Blocking question                        the hw_variant value (step 7.3)
```

**A port, not reverse-engineering** — Linux already drives this exact chip, and the
kext already implements the surrounding machinery.
