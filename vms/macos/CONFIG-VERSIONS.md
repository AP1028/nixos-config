# OpenCore config versions — ASUS Arrow Lake-H 285H laptop

Every config version that has existed on the `1401` stick, what changed, and what it
demonstrably did. Kept so no state is lost and no change is re-litigated.

Stick: `/dev/sda1`, label `1401`, ESP at `/run/media/tianyixia/1401`.
All paths below are relative to `EFI/OC/`.

| file | what it is | outcome |
|---|---|---|
| `config.plist.1401-full` | **1401's shipped base, untouched.** 27 kexts, 10 injected SSDTs, 2 ACPI patches, 2 DeviceProperties, SMBIOS MacBookPro16,2, boot-args `-v debug=0x100 keepsyms=1 -vi2c-force-polling` | the reference everything is measured against |
| `config.plist.minimal` | stripped: 5 kexts, 3 SSDTs | used to prove the config was not the sole fault |
| `config.plist.1401-fixed` | 1401's base + `CpuTscSync`, NVMeFix disabled, Booter trio reverted, SMBIOS iMacPro1,1 | superseded |
| `config.plist.dsmos-reached` | 6 kexts (incl. USBToolBox+UTBDefault), 4 ACPI Adds (DSDT, APIC, PLUG-ALT, USBX), 0 patches | **reached `DSMOS has arrived` + apfs + NVMe** |
| `config.plist.before-display-fix` | snapshot of the active config before the resolution change | rollback point |
| `config.plist` | **ACTIVE** — 1401's base + the two fixes + display settings | see below |

## The two fixes that matter

Derived from ACPICA source, verified against ACPICA 20160930 built from source, and
confirmed on the machine.

### 1. Repaired DSDT — `ACPI → Add: DSDT.aml`

The firmware DSDT contains **six top-level `Scope` statements whose targets only exist
inside conditional blocks**. macOS embeds ACPICA 20160930, whose two-pass namespace load
skips `If`/`Else`/`While` bodies in pass 1 (`psloop.c`) while still requiring every
top-level `Scope` target to exist. On failure `nsload.c` calls
`AcpiNsDeleteNamespaceByOwner()` — **the entire table's objects are deleted**.

Repair: `HS07` wrapped in `If (Zero)`; the five forward references (`HDAS`×2, `SPI0`×3)
wrapped in `If (One) { Scope(X) {...} }`. +20 bytes total, so it **cannot** be applied by
`ACPI → Patch` (OpenCore's patch is strictly in-place) — it must ship as a table.

Result on the machine: **14 table load failures → 4**.

### 2. Permuted APIC — `ACPI → Delete: Notebook (APIC)` + `ACPI → Add: APIC.aml`

Arrow Lake-H is the only three-core-type part (P/E/LP-E, with **two** Atom native model
IDs — `0x2` Crestmont, `0x3` Skymont). XNU's `x86_validate_topology()` panics when the
CPUID-derived thread count disagrees with the MADT. The documented workaround is to make
the six P-cores occupy ACPI UIDs 0-5.

Your table's LAPIC set is identical to the reference; only the UID assignment changed:

```
OEM:        uid 2,3,4,5 -> LAPIC 16,18,20,22
patched:    uid 2,3,4,5 -> LAPIC 32,40,48,56
            (LAPIC 0,8 -> 0,1   LAPIC 64,66 -> 14,15)
```

Result on the machine: `AppleACPICPU: ProcessorId=2 LocalApicId=32 Enabled` — the
permutation took effect.

## Required adjustments on top of 1401's base

| setting | value | reason |
|---|---|---|
| `Kernel → Add → CpuTopologyRebuild` | **disabled** | does not understand three core types; its author states this and it is what panics |
| `Kernel → Quirks → ProvideCurrentCpuInfo` | `true` | documented recipe step; note three-way disagreement across sources |
| `Kernel → Quirks → XhciPortLimit` | `true` | the USB installer must be visible; the working 265K Core Ultra config ships it |
| `UEFI → Output → Resolution` | `1920x1080` (was `Max`) | in framebuffer-fallback mode the desktop resolution **is** whatever OpenCore set |
| `UEFI → Output → ProvideConsoleGop` | `true` | keep the GOP framebuffer across handoff |

## Corrections recorded

- **`Kernel → Block` on `com.apple.iokit.IONDRVSupport` does not exist in any version.**
  It is applied by NullMoth's *post-install* script. A claim that 1401's config blocked it
  was wrong; the check found zero Block entries in every backup.
- **`CpuTscSync.kext` removed.** No evidence it helps: the TSC deltas on this machine were
  positive, and the negative ones observed earlier were caused by a `cpus=15` boot-arg
  experiment, not the hardware.
- **`msgbuf`, `ExitBootServicesDelay`, `cpus=2`, SMBIOS `iMacPro1,1` removed.** None were
  implicated in any observed behaviour; 1401's values restored.

## Known-good / known-bad / untested

**Known-good (in the active config):** repaired DSDT; permuted APIC; `xh_mtlp3` delete
(iasl-validated, 15→14 failures); USB mapping; `SSDT-USBX`; `debug=0x100`.

**Known-bad (removed):** the 18-entry ACPI delete batch and its 4-table descendant —
successes fell 12 → 10 and `Invalid handle [Not a Descriptor]` errors appeared; forcing
`PU2C`/`PU3C` conditions true — failures went 2 → 170 under `acpiexec`; the `UBTC → XBTC`
rename — disproved by OCR.

**Untested as single variables:** the Booter trio against the current failure point;
`ProvideCurrentCpuInfo` true vs false; `_OSI→XOSI` + `SSDT-XOSI`; the nine other SSDTs
from 1401's config; the remaining ~20 kexts.

## Current failure point

Booting to `launchd`, spawning services (`fskit`, `storaged`, `findmymacd`, `xpcproxy`),
then stopping. `shared_region ... vm_shared_region_start_address() failed` and
`denied lookup: name = com.apple.windowserver.active` appear in the log. Display path is
the prime suspect; `Resolution=1920x1080` was set to test it.
