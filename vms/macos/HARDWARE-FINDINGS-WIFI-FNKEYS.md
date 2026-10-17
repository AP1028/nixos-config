# Hardware findings — WiFi and Fn keys on the GU605CW

Measured on the machine itself (Linux side, `asusg16` / 192.168.1.250) rather than inferred
from other models. Machine: **ASUS ROG Zephyrus G16 GU605CW**, BIOS `GU605CW.311 11/20/2025`,
Core Ultra 9 285H (Arrow Lake-H), macOS 15.8.1.

---

## 1. WiFi — NOT POSSIBLE. The card has no macOS driver.

### What the card is

```
$ lspci -nn
00:14.3 Network controller [0280]: Intel Corporation Arrow Lake CNVi WiFi [8086:7740]
        Subsystem: Intel Corporation Device [8086:00e4]
        Kernel driver in use: iwlwifi
```

`8086:7740` — **Arrow Lake CNVi**. This is the `CNVW` device in the DSDT at
`\_SB.PC00.CNVW`, `_ADR = 0x00140003` (= PCI `00:14.3`), currently hidden from macOS by
`SSDT-Disable_Network_CNVW.aml`.

### Why it cannot work

`itlwm.kext` matches broadly in its plist:

```
IOPCIPrimaryMatch = 0x00008086&0x0000ffff      # any Intel PCI device
```

so the plist is *not* the gate — the device table in the code is. Checking
`itlwm/hal_iwx/ItlIwx.cpp` (13,253 lines) for every `0x7xxx` device:

```
IDs present:  0x7A70  0x7AF0  0x7E40  0x7F70
  0x7740  ->  0 references      ← Arrow Lake CNVi   NOT SUPPORTED
  0x7E40  ->  3 references      ← Meteor Lake       supported
  0x51F0  ->  5 references      ← AX211             supported
  0x51F1  ->  2 references      ← AX211             supported
```

**`0x7740` appears nowhere in itlwm.** It would probe, find no matching config, and fail to
attach.

`AirportItlwm` is worse off: its newest official build is **Sonoma 14.4** — there is no
Sequoia release at all — and it shares the same device table.

The upstream compatibility list confirms the ceiling: MVM Gen 2 tops out at
AX101/AX200/AX201/**AX211**/AX411, MVM Gen 3 at AX210. **No Wi-Fi 7 and no Arrow Lake CNVi.**
<https://openintelwireless.github.io/itlwm/Compat.html>

1401's own PCI dataset also lacks `8086-7740`, which is consistent: it detected the card,
found no driver, and shipped the SSDT to hide it.

### Conclusion

**WiFi via the internal card is impossible on macOS.** Keep `SSDT-Disable_Network_CNVW.aml`
in place — it is doing the right thing. Use the USB Ethernet adapter, which already works.

*(Not attempted: a USB WiFi dongle or a card swap. The M.2 slot is CNVi-attached, so a
replacement would have to be a CNVi-compatible module — the AX211 is supported by itlwm, and
is the only realistic hardware route if internal WiFi is ever required.)*

---

## 2. Fn keys — the transport is USB HID vendor page 0xFF31

### The keyboard

```
$ lsusb
Bus 003 Device 003: ID 0b05:19b6 ASUSTek Computer, Inc. ITE Device(8910)
```

### The decisive measurement

The HID report descriptor for that device was parsed directly:

```
$ cat /sys/bus/hid/devices/0003:0B05:19B6.0001/report_descriptor   # 745 bytes

USAGE PAGES: 0xFF89 0x06C0 0xFF31 0x02B1 0x0775 0x0109 0x3809 0xC0C0
0xFF31 present: True
```

**Usage page `0xFF31` is present.** That is ASUS's vendor hotkey page, and it is where the Fn
keys live — **not** the ACPI path.

### The ACPI path also exists — which is a trap

From the machine's own DSDT:

| Symbol | Occurrences | Meaning |
|---|---|---|
| `Device (ATKD)` | 1 | the ASUS ATK device |
| `ATKD._HID` | — | **`PNP0C14`** ("Windows Management Instrumentation Device") |
| `ATKP` | 58 | ATK presence flag |
| `IANE` | 63 | the ATK event method |
| `_WDG` | 4 | ACPI-WMI mapping |
| `_WED` | 2 | WMI event data |
| `SKBV` | **0** | keyboard backlight method — **absent** |

**So AsusSMC *would* load on this machine.** Its `IONameMatch` list includes `PNP0C14`, and
`ATKD._HID` is exactly that, with `IOProbeScore = 9999`. It would then immediately perform
blind EC writes (WMI init `0x54494E49`, ALS enable `DEVS 0x00050001`, RSOC `0x00120057`).

**But it would not help**, because the Fn keys do not arrive via `ATKD.IANE`. The realistic
outcome is "loads, does nothing for the Fn keys, possibly caps the battery at 80%."

`SKBV` being absent independently confirms the research's prediction that keyboard backlight
on ROG machines is an **HID feature report**, not an ACPI method.

### Conclusion

```
macOS has no driver for usage page 0xFF31          -> Fn keys are dead
AsusSMC listens on the ACPI path, not this one     -> cannot help
AsusSMC WOULD still load (PNP0C14, score 9999)     -> actively risky
ROG-HID matches 0b05:19b6 on paper                 -> only off-the-shelf candidate,
                                                       but a 2022 DriverKit dext,
                                                       untested on macOS 15 with
                                                       amfi=0x80 + SecureBootModel=Disabled
```

**Recommendation: do not install AsusSMC.** If Fn keys matter, ROG-HID is the only
off-the-shelf option and should be treated as an experiment with a backup EFI. A purpose-built
kext porting the `0xFF31` table from Linux's `hid-asus.c` into Apple Top Case usages is the
only route with a sound basis — that is new development, and is essentially what the
abandoned `AsusHID` was.

**Brightness workaround that does work:** `BrightnessKeys.kext` is already installed and hooks
the standard Consumer-page brightness usages, so a Karabiner rule emitting brightness up/down
from e.g. Ctrl+F1/F2 will function. Karabiner **cannot** remap the Fn keys themselves — macOS
never receives those usages, so there is nothing to remap.

---

## 3. Audio - SUPERSEDED, see section 7

*(This section originally corrected a claim that no audio driver was installed. AppleALC
is indeed present and enabled - but audio still does not work, for a different reason:
the codec is on SoundWire. See section 7.)*

An earlier report stated there was no audio driver and suggested the volume Fn keys might be an
audio-stack symptom. **That is wrong.** The config has:

```
AppleALC.kext                       enabled=True
DeviceProperties layout-id          PciRoot(0x0)/Pci(0x1f,0x3)
```

AppleALC is enabled with a layout-id on the HD Audio controller. Audio is therefore not the
blocker for volume keys — the `0xFF31` transport is.

---

## 4. Current macOS state, verified before the test boot

```
/efi/EFI/OC/Kexts/VoodooI2CHID.kext/Contents/MacOS/VoodooI2CHID   187792 bytes  (locally built)

Kernel -> Add, all enabled:
  Lilu.kext, VirtualSMC.kext, AppleALC.kext
  VoodooGPIO -> VoodooI2CServices -> VoodooInput -> VoodooI2C -> VoodooI2CHID
  (issue #372 ordering)

boot-args:        -v debug=0x100 keepsyms=1 -vi2c-force-polling
FixupAppleEfiImages: False        (required for the Secure Boot hash to match)
SecureBootModel:  Disabled
Target:           15 on the internal ESP (no file logging), 79 on the USB
```

**Pending test:** whether the locally built `VoodooI2CHID` loads where Dortania's prebuilt
binary (commit `5c0c99c`) did not.


---

## 5. Fn keys — raw HID capture (measured, not inferred)

To determine which Fn keys could ever work on macOS, raw HID reports were captured directly
from the keyboard while every Fn key was pressed.

**Method**

```bash
# locate the node:
#   /sys/devices/pci0000:00/0000:00:14.0/usb3/3-6/3-6:1.0/0003:0B05:19B6.0001  ->  /dev/hidraw0
python3 /tmp/hidcap.py 150      # reads /dev/hidraw0, groups reports by report ID
```

### Results — five report IDs on the wire

| Report ID | Collection | macOS |
|---|---|---|
| `0x01` | Generic Desktop / Keyboard | normal typing |
| `0x02` | **Consumer (`0x000C`)** | **handled natively** |
| `0x03` | — | single report only |
| `0x05` | — | periodic keepalive, payload always `0500` |
| `0x5A` | **ASUS vendor (`0xFF31`)** | **no driver exists** |

### Report `0x02` — Consumer page → **WORKS ON macOS**

| Usage | Meaning |
|---|---|
| `0xE9` | Volume Increment |
| `0xEA` | Volume Decrement |
| `0xE2` | Mute |

### Report `0x5A` — vendor page `0xFF31` → **DEAD on macOS**

| Usage | Meaning |
|---|---|
| `0x10` | Brightness down |
| `0x20` | Brightness up |
| `0x38` | unmapped |
| `0x6B` | Touchpad toggle |
| `0x6C` | Sleep |
| `0x7C` | Mic mute |
| `0xAE` | Fan mode (Fn+F5) |
| `0xB3` | Fn+Right (end) |
| `0xC4` | Keyboard backlight up |
| `0xC5` | Keyboard backlight down |
| `0x00` | idle / key release |

### The key conclusion

**ASUS splits the keys.** Volume and mute go out on the standard Consumer page —
**so three Fn keys should already work in macOS with no kext at all.** Everything else is on
the vendor page and needs a driver.

This **corrected an earlier over-broad conclusion** ("the Fn keys are on 0xFF31, therefore all
dead"). The accurate statement is that the *media* keys are standard; the rest are vendor.

### Incidental confirmation

Keyboard backlight is confirmed to be an HID **feature report** on the vendor page
(`0xC4`/`0xC5`) rather than the ACPI `SKBV` method — which is absent from this machine's DSDT.
That independently validates the ACPI analysis in section 2.

---

## 6. Custom kext for the vendor row — feasibility

### Already done

The reverse-engineering. The complete usage table is in section 5.

### What makes it small

- **Dispatching brightness is well-trodden.** `BrightnessKeys`, `VoodooPS2` and `AsusSMC` all
  do it: build an `IOHIDEvent` on `kHIDPage_AppleVendorTopCase` (`0x00FF`) and dispatch it.
  Roughly 50-100 lines.
- **A working kext build toolchain now exists on this machine** — proven by building
  `VoodooI2CHID` from source (see `VOODOOI2CHID-PR75-MERGE.md`).

### What makes it real work

1. **Matching a device Apple already owns.** The approach is to match
   `IOProviderClass = IOHIDDevice` with `PrimaryUsagePage = 0xFF31, PrimaryUsage = 0x01`, to
   claim only the vendor collection rather than the whole keyboard. **Whether macOS 15 permits
   a third-party kext to attach there, alongside Apple's HID stack, is the single genuinely
   uncertain step** and would need experimentation.
2. **The backlight protocol is not in the report descriptor.** It requires an HID *feature
   report*; the write format and value range live in firmware and in Linux's `hid-asus.c`.
   Portable, but guess-and-check.
3. **Slow test cycle** — rebuild, install to ESP, reboot, verify. This is the real cost and it
   multiplies with each uncertainty above.

### The shortcut that changes the estimate

**Port ROG-HID rather than writing from scratch** — <https://github.com/black-dragon74/ROG-HID>.
It already matches `0b05:19b6` and translates `0xFF31` usages into Apple Top Case usages,
including keyboard backlight. Its problem is **packaging, not design**: it is a 2022 DriverKit
dext requiring SIP disabled, a developer account and `systemextensionsctl developer on`, and
whether a dext loads under `amfi=0x80` + `SecureBootModel=Disabled` is unverified. Lifting its
usage table and control flow into an ordinary kext avoids all of that.

### Estimate

```
Brightness + touchpad toggle, as a kext     ~1-2 days   (mostly the matching experiment)
Keyboard backlight                          +1-2 days   (protocol work)
Testing / iteration                         the long pole - a reboot per cycle
```

**Verdict: a few days of focused work with one bounded uncertain step. Not a research project.**
The unknowns are now enumerable, which they were not before the capture.

### Cheaper things to try first

1. **Volume up / down / mute** — Consumer page, should already work. Test this first.
2. **Brightness on other keys** — `BrightnessKeys` + a Karabiner rule on Ctrl+F1/F2. Works
   today with zero development.
3. **`hidutil`** — mapping page `0xFF31` usages directly. Almost certainly cannot work, since
   macOS generates no events for that collection, but it is a 2-minute test against a 2-day
   project.

---

## 7. Audio - NOT POSSIBLE internally (SoundWire codec)

Measured in macOS:

```
AppleHDAController      loaded (600.2) but bound to NOTHING
HDEF@1F,3   (00:1f.3)   IOPCIDevice present, registered, active - NO driver child
IOHDACodecDevice        0 instances
IOAudioDevice           0 instances
system_profiler         zero audio devices
```

`AppleHDAController` matches by **PCI class**, not device-id
(`IOPCIClassMatch = 0x04010000&0xFFFD0000`, satisfied by the device's
`class-code = 0x040380`). So this is not a device-id problem - there is simply
**no codec for it to enumerate**.

From the machine's own DSDT:

```
Device (HDC1)
    Name (_HID, "10EC1308")     <- Realtek ALC1308
    Name (_DDN, "Intel(R) Smart Sound Technology Audio Codec")
Device (SNDW)  + mipi-sdw-* properties
```

**The codec is a Realtek ALC1308 on SoundWire / I2C, not a legacy HDA codec.**
macOS's AppleHDA only speaks legacy HDA; there is no SoundWire audio driver in
macOS. This is the same design used across Meteor Lake / Arrow Lake / Lunar Lake
laptops.

AppleALC (1.9.9) is loaded and working correctly - it applied
`alc-layout-id = <34000000>` (52). It simply has no codec to patch.

### Workarounds

- **USB audio works natively** - `AppleUSBAudio` is loaded. Any USB DAC/headset.
- **HDMI/DisplayPort audio via the dGPU** is likely once the NVIDIA driver is
  installed - that is a separate legacy-HDA path.
- Internal speakers and headphone jack: **not possible**.

### Config bug found

`DeviceProperties -> Add -> PciRoot(0x0)/Pci(0x1f,0x3) -> layout-id` is set as an
**integer** (52). macOS requires `<data>`. The firmware value `7` was showing
instead. AppleALC compensated via its own `alc-layout-id`, so it was harmless
here, but the type should be corrected.

---

## 8. Bluetooth - hardware present, but NOT driveable (support gap, not a wall)

macOS enumerated the device on USB:

```
Bluetooth HCI
    Vendor ID:  0x8087  (Intel Corporation)
    Product ID: 0x0037
```

But `system_profiler SPBluetoothDataType` shows a **placeholder stub**:

```
Chipset: BCM_4350C2   Transport: UART   Vendor ID: 0x004C (Apple)
Address: NULL   State: Off   Firmware Version: v0 c0
```

macOS publishes that stub when it finds no supported Bluetooth hardware.

### Why it does not work

`IntelBluetoothFirmware` - checked both **master and the v2.4.0 release** -
covers:

```
0x0025 0x0026 0x0029 0x0032 0x0033 0x0035 0x0036 [0x0038] 0x07dc 0x0a2a 0x0a2b 0x0aa7 0x0aaa
```

**`0x0037` is absent from all of them**, absent from `IntelBTPatcher` and
`IntelBluetoothInjector`, appears **zero times** in the source
(`BtIntelFw.cpp`, `BtIntel.cpp`, `IntelBluetoothFirmware.cpp`, `FwData.h`), and
no GitHub issue or PR mentions it.

Note the gap: `0x0035`, `0x0036` and `0x0038` are all supported, `0x0037` is not -
consistent with a chip newer than the kext's table.

### Category: this is a support gap, unlike the WiFi and audio

| Component | Why it fails | Realistic path |
|---|---|---|
| WiFi `8086:7740` | CNVi; no driver exists anywhere | none |
| Audio `ALC1308` | SoundWire; no macOS driver for the transport | USB / HDMI audio |
| **BT `8087:0037`** | **standard USB; driver framework exists and works for other chips** | **add the ID + firmware blob** |

The Bluetooth hardware is an ordinary USB device, and the kext already drives
twelve other Intel chips. What is missing is (a) the device ID in the plists and
(b) a firmware blob mapped for this chip. Linux drives it via mainline `btintel`,
so the firmware is obtainable from `linux-firmware`.

**Verdict: not driveable today, but it is a development task rather than an
architectural dead end.**

**>> Full work item: see `BLUETOOTH-BLAZARU-PORT.md`** - the chip is Intel
"BlazarU" (type 0x1d), firmware `ibt-0093-0291.sfi` (already extracted), and the
port is fully specified there.
