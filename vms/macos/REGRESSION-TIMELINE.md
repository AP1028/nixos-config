# Bare-metal boot: did it regress to "stuck at ACPI"?

**Question asked:** the machine passed the ACPI stage early on (CPU lines visible), so something changed
later that regressed it to stopping *at* ACPI. Reconstruct when and why.

**Answer:** the premise is half right and half wrong, and the wrong half matters.

- **Right:** the DSDT failing to load was **never fatal by itself**. It failed in the *early* boots too.
  Any theory of the form "everything downstream of the DSDT" is **wrong** and is retracted below.
- **Wrong:** there is no evidence the boot ever became *permanently* stuck at ACPI. The snapshots that
  appear to show that were taken **mid-boot**, and one real, temporary regression was caused by an
  ACPI→Delete batch I applied and then reverted.

Evidence markers: **[CONFIG]** = read from a config backup on the stick; **[OCR]** = tesseract on a
screenshot I still have; **[PHOTO]** = screenshot read by eye; **[USER]** = user's own report;
**[INFER]** = my reasoning, not observed.

---

## 1. The arithmetic that kills the DSDT theory

Two configs bracket the whole session, and both are still on the stick.

| | state A — `config.plist.minimal` | bare — `config.plist` (bare bones) |
|---|---|---|
| ACPI Add, **enabled** | **3** (SSDT-EC, SSDT-PLUG-ALT, SSDT-RTCAWAC) | **0** |
| ACPI Patch enabled | **0** (both disabled) | 0 |
| ACPI Delete | 0 | 0 |
| total tables | 27 firmware + 3 = **30** | 27 firmware + 0 = **27** |
| **observed result** | **16 fail / 14 successful** [OCR] | **15 fail / 12 successful** [OCR][USER] |

```
16 - 15 = 1   -> the single injected SSDT that failed = SSDT-EC   [OCR: "(SSDT: EC) while loading table"]
14 - 12 = 2   -> the injected SSDTs that succeeded   = SSDT-PLUG-ALT, SSDT-RTCAWAC
```

**Therefore the firmware table results are identical in both boots: 15 failures, 12 successes.**

**The DSDT failed in *both*.** It is not the differentiator, and the early boot proves a rejected DSDT
still permits `pci` → `AppleACPICPU` → SMP bring-up. **[CONFIG][OCR]**

> This also **retracts** the "everything is downstream of the ACPI failure" framing I built mid-session,
> and with it the claim that fixing the DSDT was the only thing that mattered. The DSDT repair is still
> a genuine fix (it takes 15 firmware failures to 0 on real ACPICA 20160930) but the boot did not
> regress *because* of the DSDT.

Also corrected: `config.plist.minimal` does **not** contain `_OSI→XOSI`. I briefly hypothesised that
removing the XOSI patch was the regression. **[CONFIG] disproves it** — the patch was already disabled
in the config that passed ACPI.

---

## 2. Every observed boot, in order

CPU-enumeration output is the discriminator (it is the first thing after `pci` that proves the ACPI
walk completed).

| # | config at the time | cpus=2? | observed | evidence |
|---|---|---|---|---|
| A | minimal: 5 kexts, 3 SSDTs, MATs Booter trio, `-v debug=0x100 keepsyms=1 -vi2c-force-polling` | NO | 16/14 → `pci` → **AppleACPICPU ×48** → RSP/bastion → trust caches → `mp_kdp_enter() timed-` | [OCR] |
| B | after reference fixes; `-v keepsyms=1 debug=0x12a msgbuf=1048576` | NO | **`cpu_data` remap → TSC sync → Started cpu 1..14** | [PHOTO] |
| C | + 18-entry ACPI→Delete batch | YES | stops in ACPI; **new error class "Not a Descriptor" ×4** | [PHOTO][OCR] |
| D | + 5 TB tables un-deleted, 4-table Delete | YES | **13 fail / 10 successful** — *worse*; "same place" | [USER] |
| E | 4-table Delete reverted to xh_mtlp3 only | YES | **14 fail / 12 successful**; screen ends at `pci` | [OCR][USER] |
| F | bare bones (0/0/0) | YES | **15 fail / 12 successful**; screen ends at `pci` | [OCR][USER] |
| G | repaired DSDT + permuted APIC + SSDT-PLUG-ALT | **NO** | **4 fail / 23 successful** → AppleACPICPU ×16 **with P-cores at LocalApicId 0,8,32,40,48,56** → bastion → IOAPIC → module-level AML → PCI config begin/end → NVMe → **DSMOS has arrived** → apfs_module_start | [PHOTO] |

### 2.1 Candidate evaluation

| change | can it move the stop **earlier than `pci`**? | verdict |
|---|---|---|
| **18-entry ACPI→Delete** | Only 5 of 18 names matched anything, and all 5 (`Cpu0Ist/Hwp/Cst`, `ApIst`, `CpuSsdt`) were **already failing to load** — removing them is close to a no-op. **But** boot C is where "Not a Descriptor" first appears. | **suspected co-factor** |
| **4-table Delete** (`TcssSsdt`, `TbtTypeC`, `UsbCTabl`, `xh_mtlp3`) | **Yes — demonstrated.** It removed tables that *define* objects other tables reference: successes fell 12 → 10 (two previously-working tables began failing). | **proven regression, already reverted** |
| single `xh_mtlp3` Delete | No — removes a duplicate definition; 15 → 14 failures. | **real fix, keep** |
| `cpus=2` | No — `cpus=15` still printed `Started cpu 1..14` [USER], so `cpus=` does not suppress enumeration. | correlation only, **not causal** |
| Booter trio reversal (WriteUnprot F→T, Rebuild T→F, Sync T→F) | **No — exonerated.** Boot B ran the *old* trio and still printed CPU lines. | **exonerated** |
| ACPI Quirks all→False | `ResetLogoStatus` is cosmetic. | **exonerated** |
| `debug=0x100` vs `0x12a`, `msgbuf`, `-vi2c-force-polling` | Change *how much is printed*, not progress. `0x12a` adds `DB_PRT`/`DB_KPRT` which **double every line**; `0x100` alone is correct. | output only |
| SMBIOS MacBookPro16,2 → iMacPro1,1 | Marker test; no ACPI mechanism. | **exonerated** |
| `ExitBootServicesDelay=500` | Present in boot A and in later boots alike. | no correlation |
| NVMeFix off / CpuTscSync on / DeviceProperties cleared / 4-kext strip | Kexts and properties load *after* ACPI. | **cannot** |

### 2.2 The most likely single cause

**The ACPI→Delete work changed the table set into an inconsistent state**, and that is what moved the
stop earlier:

- Boot A (no deletes) — **0** occurrences of "Not a Descriptor". **[OCR]**
- Boot C (18-entry Delete) — **4** occurrences, plus `Method parse/execution failed` on
  `\_SB.UBTC._STA`, `\_SB.NHTC._CRS`, `\_SB.PWX._STA`. **[OCR]**
- "Invalid handle … [Not a Descriptor]" is a **table-consistency** error: tables referencing handles
  that no longer exist. It had never appeared before the deletes.

**Confidence: moderate.** The 18-entry batch mostly matched nothing, so the mechanism is weaker than the
evidence for the 4-table batch — which was *demonstrably* harmful (12 → 10 successes) and **has already
been reverted**. The residual "no CPU lines" in boots E and F is better explained as **mid-boot
snapshots**: the user's own caption on the bare-bones photo was *"this is what happens before it stops,
not really 10min yet."* **[USER]**

**No single change has been isolated as a permanent regression, and the current configuration (G) is
further along than any earlier boot — so whatever it was is no longer in the config.**

---

## 3. Change log, in order, with the boot that followed

| # | change | followed by |
|---|---|---|
| 1 | reference fixes: `EnableWriteUnprotector=True`, `RebuildAppleMemoryMap=False`, `SyncRuntimePermissions=False`; NVMeFix disabled; CpuTscSync added | boot B — **CPU lines present** → **exonerates the Booter trio** |
| 2 | SMBIOS → iMacPro1,1 (config-marker test; board-id changed in the OpenCore log) | marker confirmed my config was booting |
| 3 | boot-args `-v debug=0x100 …` → `-v keepsyms=1` → `debug=0x12a msgbuf=1048576` → `debug=0x100 msgbuf=1048576` | boot B showed the most output of any boot; `0x12a` doubled every line |
| 4 | CPU-count kernel patch (`_acpi_count_enabled_logical_processors`), count 16 | **no-op — the count was already 16** |
| 5 | `cpus=15` + patch→15 | "does not progress past starting cpu 14"; **negative TSC deltas on cpu 4/5 appeared here** |
| 6 | `cpus=15` and patch reverted | deltas positive again → **the deltas were my artefact, not a machine fault** |
| 7 | `TscSyncTimeout=500000`, then reverted | set on a misreading of #5; reverted |
| 8 | 18-entry ACPI→Delete | boot C — **first "Not a Descriptor"; stop in ACPI** |
| 9 | 5 TB tables un-deleted | boot D — 13/10 |
| 10 | 4-table Delete | boot D — **successes 12 → 10 (regression)** |
| 11 | reverted to single `xh_mtlp3` Delete | boot E — 14/12 |
| 12 | bare bones: 0/0/0 ACPI, ACPI Quirks all False, 4 kexts | boot F — 15/12 |
| 13 | DSDT repaired (6 top-level `Scope` forward-refs wrapped) + APIC UID-permuted + SSDT-PLUG-ALT + `ProvideCurrentCpuInfo=true` + `cpus=2` removed | **boot G — furthest ever** |

---

## 4. Status of every change

**Known-good — in the working config (G):**

- repaired `DSDT.aml` via `ACPI → Add` (0 load failures on ACPICA 20160930, namespace byte-identical)
- `APIC.aml` UID-permuted (P-cores at UID 0-5) via Delete firmware APIC + Add
- `SSDT-PLUG-ALT` (CPUs are Devices, not `Processor` opcodes)
- `ProvideCurrentCpuInfo = true`
- single `xh_mtlp3` Delete (compiler-validated, 15 → 14 failures)
- `debug=0x100 msgbuf=1048576`, no `cpus=`
- 4 kexts, `CpuTopologyRebuild` **disabled** (it is the known-panicking kext for 3-core-type CPUs)

**Known-bad or pointless — removed:**

- 4-table Delete (proven regression, 12 → 10 successes)
- 18-entry Delete (13 of 18 names matched nothing)
- `cpus=15` / `cpus=2` (artefacts — `cpus=15` fabricated the negative TSC deltas)
- `TscSyncTimeout=500000` (set on that misreading)
- `debug=0x12a` (doubles every console line via `DB_PRT`/`DB_KPRT`)
- CPU-count kernel patch (no-op)
- `UBTC→XBTC` rename (no effect — macOS walks the whole namespace)
- `PCHA` condition patch (no effect — 14/12 identical with and without)

**Untested as single variables:**

- Booter trio in either direction, now that everything else is stable (exonerated for the ACPI stop, but
  never tested against the *current* failure point)
- `ProvideCurrentCpuInfo` true vs false (a documented three-way disagreement between Clover, an Arrow
  Lake-S build, and the hybrid-mobile workaround)
- `_OSI→XOSI` + `SSDT-XOSI` (absent from all recent configs; present only in `.1401-full`)
- the remaining 9 firmware-facing SSDTs from 1401's config (`SBUS`, `GPI0`, `MCHC`, `USBX`, …)

---

## 5. Meta-lessons: conclusions drawn from one photograph, later contradicted

Every one of these cost real time and at least one wrong patch.

| conclusion | how it was drawn | what disproved it |
|---|---|---|
| "the firmware reports 22 CPUs, patch it to 16" | one screenshot, read by eye | **OCR** gave `Enabled 16 / Disabled 31`; OCR of the *next* image gave the same. The count was always correct. |
| "the negative TSC deltas prove a machine fault" | one screenshot, taken after my own `cpus=15` change | the deltas were **caused by `cpus=15`**; positive without it |
| "the doubled console text is a camera artefact" | assumption | it was **real** — `debug=0x12a` contains `DB_PRT` (0x2), printing every line twice |
| "the `PCHA`/`PC02` conditional is why the DSDT is rejected" | AML bytes + inference | patch applied, **14/12 unchanged** — no effect |
| "`_OSI→XOSI` removal caused the regression" | correlation with the bare-bones strip | **[CONFIG]** — the patch was already disabled in the config that passed ACPI |
| "everything is downstream of the DSDT load failure" | boot order ACPI → pci → CPU | **arithmetic in §1** — the DSDT failed in the boots that *passed* ACPI too |
| "the Booter trio reversal moved the stop earlier" | it was in the same batch as the deletes | boot B ran the old trio and **still printed CPU lines** |

**The pattern:** every wrong conclusion came from reading a *single* screenshot or a *single* boot's
numbers, without checking the previous run or OCRing the image. Two habits fixed it — **OCR the
screenshot**, and **compare against the immediately preceding boot before theorising**.

**A third habit, learned late and worth keeping:** `acpiexec` (and the real ACPICA 20160930 built from
source) reproduce table-load behaviour offline. Six hypotheses could have been tested there in minutes
instead of costing six laptop boots.

---

## 6. Closing: the question is moot in practice

This document was opened to answer *what moved the stop, and was it permanent?* Neither half now affects a
decision:

- **No permanent regression existed.** The "stops after pci" snapshots were taken **mid-boot** — the
  user's own caption was *"this is what happens before it stops, not really 10min yet."* **[USER]**
- **The current configuration is far past the whole question.** With the repaired DSDT (`ACPI → Add`) and
  the permuted APIC, the boot reaches **macOS userland**: `DSMOS has arrived`, APFS loaded, NVMe
  initialized, `com.apple.xpc.launchd` spawning services. Table failures went **14 → 4**. Whatever moved
  the stop earlier is no longer in the config.
- **The one demonstrably harmful change is already reverted** — the 4-table deletion that took successes
  from 12 to 10.

**§4's inventory above is superseded.** Its "known-good" list describes the 4-kext bare-bones state, which
was itself a mistake: stripping 1401's config removed `SSDT-EC`, `SSDT-XOSI`,
`AppleMCEReporterDisabler`, `RestrictEvents`, the `DeviceProperties` and the USB map. Every config
version, both working fixes, the corrections, and the current known-good / known-bad / untested lists now
live in **[`CONFIG-VERSIONS.md`](CONFIG-VERSIONS.md)**.

This file is kept for two things: the change log in §3, and §5 — the record of conclusions drawn from a
single photograph and later contradicted. That part is still worth reading before theorising from one
screenshot.

**Current failure point** — a *different* question, recorded here only for continuity: the boot reaches
`launchd` / userland and stops, with `denied lookup: name = com.apple.windowserver.active` and
`shared_region ... vm_shared_region_start_address() failed` in the log. Prime suspect is the display path:
on a fresh install there is no NVIDIA driver, so the firmware framebuffer (`IONDRVFramebuffer`) is the
only thing that can drive the panel. `UEFI → Output → Resolution` was changed from `Max` to `1920x1080` to
test it.
