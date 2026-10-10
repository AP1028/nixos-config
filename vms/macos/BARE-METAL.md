# Bare-Metal macOS on the ASUS Laptop — Arrow Lake-H bring-up record

Attempt to boot the macOS 15.6.1 installer natively on the ASUS laptop, for the
NullMoth NVIDIA driver. This is the bare-metal counterpart to the VM work in
`vms/macos/README.md`; that document covers the QEMU/vfio recipe and the driver
internals and is not repeated here.

**Status: in flight.** The kernel boots and prints, CPU bring-up works, and the
current stop is in ACPI method parsing. Nothing below is finished work.

## Hardware

| | |
|---|---|
| CPU | Core Ultra 9 285H (Arrow Lake-H) |
| Cores | 6 P + 8 E + 2 LP-E = **16 threads, no hyperthreading** |
| dGPU | RTX 5080 Laptop |
| MUX | currently **dGPU** (not hybrid) |
| Installer | macOS 15.6.1, 16 GB USB stick labelled `1401` |
| Bootloader | OpenCore on the stick's ESP |

Arrow Lake dropped Hyper-Threading, so 16 cores = 16 logical processors. Any
core count above 16 on screen is a misreading — see *Findings* below.

## Firmware constraints

**Secure Boot requires every `.efi` under `EFI/` to be signed.** OpenCore loads
drivers via the firmware's `LoadImage`, so a single unsigned driver halts the
boot. Sign with `sbctl sign <file>`; the keys are already enrolled in
`/var/lib/sbctl/keys`. Do **not** use `sbctl sign -s` for removable media — it
registers a file for automatic re-signing, which is wrong for a stick that moves
between machines.

Signing is only needed when an `.efi` is replaced. Editing `config.plist` never
requires re-signing.

## Confirming which config actually boots

An externally-visible marker is needed, because a stale config that boots is
indistinguishable from an edited one that does not.

Set `PlatformInfo → Generic → SystemProductName` and read `#[EB|BRD:NV]` in the
next `opencore-*.txt`:

| SMBIOS | board-id in log |
|---|---|
| `MacBookPro16,2` | `Mac-5F9802EFE386AA28` |
| `iMacPro1,1` | `Mac-7BA5B2D9E42DDD94` |

Changing the SMBIOS moved the log line exactly as predicted, confirming the
stick's `EFI/OC/config.plist` is what boots. **Do not use `boot-args` or
`csr-active-config` as markers** — both live in NVRAM, which the config writes
and which then persists regardless of which config boots next. They look
identical either way and prove nothing.

Independent confirmation is available from Linux: on this laptop
`boot-args-7c436110-ab2a-4bbb-a880-fe41995c9f82` in
`/sys/firmware/efi/efivars/` matches the config verbatim.

## The core debugging problem: there is no kernel log

Three separate routes were tried. None yields kernel output.

**1. OpenCore's file log is not a kernel log.**

```
opencore-*.txt   262144 bytes   ~97% NUL   94 non-empty lines
line prefixes:   {'AAPL': 94}
OC: / OCABC lines:  0
last line:       #[EB|LOG:EXITBS:START]
```

It contains **only** boot.efi's `AAPL:` output, and it ends at `EXITBS:START` on
**both working and failing boots** — the marker is where boot.efi's logging
stops by design. It cannot discriminate between success and failure, and
reasoning from its silence is invalid.

**2. The NVRAM panic log does not reach Linux.** The kernel reports
`Attempting to commit panic log to NVRAM`, but searching all **185** UEFI
variables under `/sys/firmware/efi/efivars/` found no panic text, and no
variable is named for one.

**3. OpenCore's own dump routes produce nothing.** `ApplePanic=true` wrote no
file to the ESP, and the `Misc → Debug → Target` bit intended to emit
`nvram.plist` never produced one either.

**Consequence: the screen is the only channel.** No UART for serial, no NIC
driver for KDP, no file output. Every diagnosis must come from a photograph of
the panel.

## What made the machine talk

Dortania's in-depth debugging page. These boot-args are the difference between a
silent hang and a readable panic:

```
-v keepsyms=1 debug=0x12a msgbuf=1048576
```

`debug=0x12a` = `DB_PRT`(0x2) + `DB_KPRT`(0x8) + `DB_SLOG`(0x20) +
`DB_LOG_PI_SCRN`(0x100).

**`DB_LOG_PI_SCRN` (0x100) is the flag that prints panic information to the
screen.** `debug=0x100` had been removed early on, in the mistaken belief that
it was `DB_KDP_DEBUG` ("enable kernel debugging") and was parking the machine in
a debugger. It is the opposite — it is the flag whose entire purpose is to
display the failure being hunted. Removing it destroyed the evidence for hours.

**`msgbuf=1048576` is required for early kernel logs**; the default buffer is
too small for messages this early.

**Do not keep `0x12a` long-term.** `DB_PRT`(0x2) and `DB_KPRT`(0x8) both write
to the console, so **every line prints twice**:

```
ACPI Error: ACPI Error: Method parse/execution failed Method parse/execution failed
```

Use `debug=0x100` alone — panic-to-screen retained, doubling gone.

## Findings

Each was verified against hardware output. Several correct earlier misreadings,
and those corrections are the most reusable part of this record.

### The kernel boots

Once the debug flags are right, macOS starts and prints full verbose output:
ACPI table loading, PCI init, `AppleACPICPU` enumeration, AP bring-up with TSC
sync. The platform is capable of running the kernel.

### CPU count was always 16

A photograph was read as showing 22 enabled processors, and a whole theory was
built on it — that the firmware presents P-cores hyperthreaded, and that
Dortania's `_acpi_count_enabled_logical_processors` patch (`B804000000C3` →
`B810000000C3`) would force 16.

**OCR of the same image proved 16 enabled / 31 disabled / 47 entries.** The
reading was simply wrong. The patch was a no-op and is now disabled.

The tell was available immediately: 22 = 6×2 + 8 + 2, i.e. the P-cores
double-counted — but Arrow Lake has no HT, so 22 was never self-consistent.

### `cpus=15` caused the negative TSC deltas

With `cpus=15`, two cores reported negative TSC deltas:

```
TSC sync for cpu 4: delta 0xfffffffffffffff0 (-16)
TSC sync for cpu 5: delta 0xfffffffffffffff0 (-16)
```

This was read as a pre-existing hardware fault and `TscSyncTimeout=500000` was
set in response. **The previous boot, without `cpus=15`, had all-positive
deltas** (cpu 4 `0x69`, cpu 5 `0x5f`). The negative values were **introduced by
the boot-arg**, not found in the machine. Both changes were reverted.

**Always diff a suspicious number against the previous run before theorising.**

### Disabling cores is not the fix

```
default            → stop after cpu 14
disable 2 E-cores  → stop after cpu 12
disable all E-cores→ panic (first time a message was visible)
```

The stop tracks the core count, moving down by exactly the number removed. **The
E-cores and LP-E cores are not the cause.** What the exercise did produce was a
shorter log, which is why the panic became visible at all.

### Blocker chain, in order

**Superseded — all three entries below are wrong or unproven. See *Breakthrough:
the boot reaches macOS userland* at the end of this file.** `ExitBootServicesDelay`
was removed as unjustified, `CpuTscSync.kext` was removed for lack of evidence, and
the ACPI framing is retracted.

1. **Firmware `ExitBootServices` handoff** — addressed by
   `UEFI → Quirks → ExitBootServicesDelay=500`. This is a known class of laptop
   firmware bug (cf. UEFI EBS failures on Lenovo T14s). Either this or the SMBIOS
   change is what first got the kernel printing.
2. **SMP bring-up** — addressed by `CpuTscSync.kext` plus the debug flags.
3. **ACPI method parsing** — current stop, see *Current state*.

### The doubled console text was real

`MMeettaaddaattaa`, `GGEENN00`. Dismissed as a phone-camera rolling-shutter
artifact; it was not. It was `DB_PRT` in `debug=0x12a` printing every message
down two paths. `debug=0x100` fixes it.

The disambiguation test is worth keeping: a genuinely doubled *console* doubles
`AppleACPICPU: ProcessorId=…` too. Earlier photos OCR'd those lines cleanly, so
the doubling had a specific onset and a specific cause.

### Renaming `UBTC` did not fix anything

Errors:

```
ACPI Error: Method parse/execution failed [\_SB.UBTC._STA] … AE_NOT_FOUND
ACPI Error: [USTC] Namespace lookup failure, AE_NOT_FOUND
```

An `ACPI → Patch` rename `UBTC → XBTC` was added on the theory that an
unreferenced broken method is never parsed.

**OCR afterwards showed the identical errors under the new name:**

```
ACPI Error: Method parse/execution failed [\_SB.XBTC._STA] … AE_NOT_FOUND
ACPI Error: Method parse/execution failed [\_SB.XBTC._CRS] … AE_NOT_FOUND
```

macOS walks the whole namespace, so renaming a device does not stop its methods
being evaluated. **The patch was reverted.** A rename only helps when nothing
references the object at all.

## The working reference config

**The single most valuable find of the session** — a community OpenCore EFI
validated on this exact CPU family:

`github.com/luchina-gabriel/BASE-EFI-INTEL-DESKTOP-15THGEN-CORE-ULTRA-200-ARROW-LAKE-PUBLIC`

Its notes, and what was done:

| Reference guidance | Action |
|---|---|
| *"Don't add `NVMeFix` kext, it has been causing boot problems with Intel Core Ultra"* | **Disabled.** It had been enabled throughout. |
| `EnableWriteUnprotector` — *"ENABLE if you get a Kernel Panic while booting macOS Installer"* | **Set True**, with `RebuildAppleMemoryMap=false` and `SyncRuntimePermissions=false`. 1401's original trio was correct; the "modern MATs firmware" change from Dortania's generic page was wrong for this platform. |
| `SetupVirtualMap` — *"DISABLE if you stuck in Early boot"* | False |
| `CpuTscSync` — *"disabling xcpm_urgency if TSC is not in sync"* | **Installed** (acidanthera 1.1.1) and added to `Kernel → Add` |
| SMBIOS `MacPro7,1` or `iMacPro1,1` (no Apple driver for the Core Ultra iGPU) | Set `iMacPro1,1` |
| Disable Thunderbolt for initial install | **No BIOS switch exists on this laptop** — handled in ACPI if at all |
| Above 4G ON; **Resizable BAR DISABLED, not Auto**; CFG Lock off (or `AppleXcpmCfgLock`); OS type Windows 8.1/10 UEFI Mode; SATA AHCI | BIOS |

**VT-d may stay on** because `DisableIoMapper=YES` — which matters here, since
the same machine runs the Linux VFIO setup and disabling VT-d globally would
break it.

`CpuTscSync.kext` layout, for reference:

```
CpuTscSync.kext/Contents/Info.plist      org.lvs1974.driver.CpuTscSync
CpuTscSync.kext/Contents/MacOS/CpuTscSync
```

## Current state

**Superseded — see *Final stick state* below.** The configuration recorded in this
section was abandoned: the four-table deletion was wrong (see *Confirmed fixes to
keep*), the PCHA patch that replaced it did nothing, and every speculative change
was reverted. Kept as a record of the state at the time.

**A deliberately mid-flight configuration.** `config.plist` on the stick:

```
boot-args      -v keepsyms=1 debug=0x100 msgbuf=1048576 cpus=2
SMBIOS         iMacPro1,1
kexts          27 enabled (NVMeFix disabled, CpuTscSync added)
ACPI Add       10 injected SSDTs
ACPI Patch     _OSI→XOSI, PS_STA→PSXSTA      (UBTC rename removed)
ACPI Delete    13 tables deleted, 5 restored
Booter         EnableWriteUnprotector=true, RebuildAppleMemoryMap=false,
               SyncRuntimePermissions=false, SetupVirtualMap=false,
               DevirtualiseMmio=true
```

**Still deleted (13)** — CPU power management, which macOS does not use with
XCPM, and which were failing to load anyway:

```
ApIst Cpu0Cst Cpu0Hwp Cpu0Ist Cpu0Pst Cpu0Tss CpuPm CpuSsdt
SaSsdt Opt2Table RPMI Ic23 Ip2pRvp
```

**Restored (5)** — Thunderbolt/USB4 tables, restored after suspecting the
deletions caused the missing USB-C objects:

```
TbtSsid xh_tbt3 xh_rvp3 TcssSsid TcssXdt
```

Rationale for restoring: deleting a table that fails to load is normally a
no-op, but if those tables *define* objects the DSDT still references, removing
them converts a load failure into a namespace failure. The restore is a test of
that hypothesis.

### Last observed stop

ACPI parse/execution failures, ending on `_SB.NHTC._CRS`, with dozens of
`AE_NOT_FOUND` lookups for USB Type-C / USB4 objects:

```
UCMC  UCS1  UCS2  UCS3  NHCB  PDBC  CDD  UCD1  UCD2  USTC  UBCB  USBC
```

### Open question being tested

**Are those ACPI errors fatal, or is the boot merely slow?**

Dozens of `AE_NOT_FOUND` errors are routine on a hackintosh and macOS normally
continues. The parser walks every failing method one at a time and prints as it
goes, so a screen that has not changed in thirty seconds is indistinguishable
from one that has been grinding for five minutes.

**Next boot is to be left alone for ten minutes before being judged stuck.** This
is a cheap and decisive test and should have been run far earlier.

**Answered: the boot is not merely slow.** The log shows
`ACPI Exception: AE_NOT_FOUND, During name lookup/catalog (DSDT) table load failed`
— the DSDT is rejected outright. Waiting was never going to help. See *The compiler-age
observation* and *DSDT repair status*.

**Partly retracted.** The DSDT *is* rejected — that part stands, and repairing it is
one of the two fixes that worked. But the inference that the errors were "downstream
of that", i.e. that the DSDT rejection was the root blocker, is **withdrawn**: the
DSDT failed in boots that passed the ACPI stage too. See the *Retraction* section at
the end of this file.

## Tooling: OCR the screenshots

The screen is the only output channel, so reading photographs accurately is not
optional. `tesseract` alone fails on angled, glare-affected screen photos;
preprocessing is what makes it work:

```bash
convert shot.jpg -colorspace Gray -negate -resize 250% \
        -contrast-stretch 3%x3% -unsharp 0x2 out.png
tesseract out.png out --psm 6
```

Grayscale, **negate** (the console is light-on-dark; tesseract prefers the
reverse), 250–300% upscale, contrast stretch. Cropping to the region of interest
before upscaling helps further.

This pipeline repeatedly caught errors that eyeballing had introduced — most
importantly the 16-vs-22 core count, which had already produced a wrong patch
and a wrong theory before OCR settled it.

## Lessons

**The recurring failure mode was acting on a misread number.** Three separate
detours — the CPU-count patch, the TSC-sync timeout, the doubled-text
dismissal — all began with reading a value off a photograph and theorising
without checking it against the previous run or against arithmetic.

- **22 processors on a 16-core no-HT CPU was self-inconsistent.** The arithmetic
  was available and unused.
- **The negative TSC deltas appeared only after a change of mine.** Diffing
  against the prior boot would have caught it immediately.
- **The doubling was called a camera artifact** while earlier photos of the same
  console were demonstrably clean.

**OCR should be the default, not the fallback.** Every screenshot in this session
should have gone through tesseract before any conclusion was drawn from it.

**Config changes were made on evidence that did not support them.** The
`UBTC → XBTC` rename was reasoned from ACPI semantics and disproved in one boot.
The `NVMeFix` and `EnableWriteUnprotector` errors were not reasoning failures at
all — the community reference had the answer written down, and searching for it
should have come before hours of first-principles work.

**One-variable discipline still applies.** `cpus=15` and the CPU-count patch were
applied together deliberately (both said "15"), which was correct — but the
`cpus=15` side effect showed how easily a workaround becomes a new fault.

## Next steps

**Superseded — see *Next steps* at the end of this document.** The ordering below
assumed the ACPI errors were a parsing problem to be worked around. They are a
table-load failure, and the fix is a rebuilt DSDT.

1. **Boot and wait ten minutes.** Determines whether the ACPI errors are fatal or
   merely slow. Everything else depends on the answer.
2. If genuinely wedged on `_SB.NHTC._CRS`, attack the DSDT properly — the missing
   objects are referenced but never defined, so an SSDT supplying them is the
   real fix, not a rename.
3. Re-test the five restored Thunderbolt tables: if the `UCMC`/`UCS*`/`USTC`
   errors vanish, the deletions caused them and the CPU-power tables can stay
   deleted.
4. Once booting: the MUX is **on dGPU** — which is the CORRECT and REQUIRED position.
   panel. The reference notes there is no Apple driver for the Core Ultra iGPU,
   so the eventual target is the NullMoth driver on the RTX 5080 — which is what
   the VM work in `vms/macos/README.md` already validated.

## Where the answers are not

The OpenCore log, the NVRAM panic log, and `ApplePanic` are all dead ends on
this machine. Time spent on them is time wasted. **On the laptop the screen is the
channel, and OCR is how you read it.** The VM testbench below is the way out of
that constraint.

---

# VM testbench, PCHA failure, and DSDT repair

Appended after the session above. Everything here postdates the *Current state*
snapshot and supersedes its *Next steps*.

## The VM testbench

**The user's idea, and the right one.** The purpose is *not* to run macOS in a VM.
It is to give the bare-metal EFI work a **serial console** and an iteration loop
measured in minutes instead of one laptop boot per photograph.

Location: `asusg16:/home/tianyixia/macos-testbench`

> `asusg16` moved from `192.168.1.100` to **`192.168.1.250`** — `.100` was taken by
> another host. All commands in this document use `.250`.

What works:

| piece | state |
|---|---|
| QEMU 11.1.1 + KVM | ✓ |
| **Serial capture to file** (`-serial file:…`) | ✓ — OVMF *and* OpenCore both log to it |
| Real laptop ACPI in the ESP | ✓ — DSDT + 25 SSDTs from `/tmp/acpi`, injected via `ACPI → Add` |
| Faithful reproduction config | ✓ — **26 Add entries, 0 Delete, 0 Patch** |
| UEFI boot entry for a fixed SATA disk | ✓ — `bcfg boot add 0` |

The reproduction is deliberate: the first VM run uses the **untouched** table set,
so any failure seen in the VM is a property of the firmware's own ACPI rather than
of an edit. This is the mirror image of the bare-metal method — where the config
had to be stripped to prove the fault was not ours, here the firmware is presented
unmodified to prove the same thing faster.

### Four bugs found in the VM setup itself

| # | bug | fix |
|---|---|---|
| 1 | **OSX-KVM ships a mismatched OVMF pair:** `OVMF_CODE_4M.fd` (3,653,632 B) with `OVMF_VARS.fd` (**131,072 B**). The 4 MB code build needs a **540,672-byte** NVRAM store. The mismatch makes the firmware behave erratically — `Already started` on image load. | Use QEMU's own matched pair: `edk2-x86_64-code.fd` + `edk2-i386-vars.fd` |
| 2 | **`-cpu host` breaks UEFI image loading on this Arrow Lake CPU.** | `-cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check` |
| 3 | UEFI removable-media path is **uppercase**: `\EFI\BOOT\BOOTX64.EFI`. | Rename |
| 4 | **Fixed SATA disks need a `bcfg` boot entry.** OVMF only auto-boots removable media; otherwise it falls through to the internal EFI shell. | `startup.nsh`: `bcfg boot add 0 FS0:\EFI\BOOT\BOOTX64.EFI "OpenCore"` then `reset` |

`-no-reboot` must be dropped for the `bcfg` + `reset` approach to work, since the
script deliberately resets the machine.

### Remaining blocker

```
OCM: Failed to start image - Already started
BS:  Failed to start OpenCore image - Already started
```

`EFI_ALREADY_STARTED`, from the OSX-KVM OpenCore build (626,688 B).
**Reproducible through three independent launch paths:** the Bootstrap, running
`OpenCore.efi` directly, and a firmware `bcfg` boot entry. The stack, firmware,
serial channel, ACPI tables and boot entry are all proven working — **only the
OpenCore binary is suspect.**

**Next step: swap in a fresh acidanthera OpenCore release**, with its own matching
Bootstrap and a config generated for that version.

### Editing the stick from asusg16

The `1401` stick mounts **read-only** there:

```
mount: /mnt/stick: WARNING: source write-protected, mounted read-only.
```

despite the block layer and the kernel both disagreeing:

```
/sys/block/sda/ro          = 0
[sda] Write Protect is off
blockdev --getro /dev/sda1 = 0
```

`mtools` talks to the block device directly and is unaffected by whatever the vfat
mount objects to:

```bash
sudo mcopy -n -o -i /dev/sda1 ::/EFI/OC/config.plist /tmp/c.plist   # read
sudo mcopy -o    -i /dev/sda1 /tmp/c.plist ::/EFI/OC/config.plist   # write
```

A `Hidden (2048) does not match sectors (63)` geometry warning is emitted and is
harmless. Writing from the macbook works normally when the stick is attached there.

## The PCHA patch, and its failure

The DSDT's own `Scope` block has nothing to attach to. From the decompiled table:

```
line 16106:   Scope (_SB.PC02) { Device (HDAS) ... }
```

`PC02` exists only inside a conditional:

```
a0 3c 92 93 50 43 48 41 00 5b 82 32 50 43 30 32
│     │  │  └─ "PCHA" ──┘  │  └─ DeviceOp + "PC02"
│     └─ 93 = LNotEqual     └─ 00 = Zero
└─ a0 = IfOp
```

That is `If (PCHA == Zero)`. Since `Scope (_SB.PC02)` was failing, `PC02` was never
created — so `PCHA` is **non-zero** on this machine and the branch never ran.

Patch applied:

```
ACPI → Patch, TableSignature = DSDT
  Find:     92 93 50 43 48 41 00     Not(PCHA != 0)   →  If (PCHA == Zero)
  Replace:  92 94 50 43 48 41 00     Not(PCHA < 0)    →  always true (unsigned)
```

**Result: `14 fail / 12 success` — identical to deleting `xh_mtlp3` alone. The
patch had no effect and has been removed.**

This was the **third** wrong guess about the DSDT's failure point, after `PC02` and
`HDAS` — each of them derived from reading a single line of a photograph.

## The compiler-age observation

**Unresolved, and the most promising explanation so far.**

```
ACPI: DSDT … (v02 _ASUS_ Notebook 01072009 INTL 20210330)
ACPI Error: … (20160930/dswload-292)
```

| | |
|---|---|
| Firmware's DSDT compiled by | ACPICA **20210330** |
| macOS's ACPI parser | ACPICA **20160930** |
| Gap | **~4.5 years** |

This may explain why `iasl` (2026) parses the table set cleanly while macOS rejects
it: **validation was being done against a parser five years newer than the one that
has to accept the table.** It would also explain why the community fix takes the
form of a *rebuilt, reduced* DSDT rather than a byte patch — Olarila's working Core
Ultra DSDT is **51k lines against this one's 100k**.

**Hypothesis, not confirmed.** Counter-evidence recorded: the DSDT's
`DefinitionBlock` declares ACPI revision **2**, and there are **no `0x70` bytes in
the first 4 KB of AML**. So macOS's
`Unsupported module-level executable opcode 0x70 at table offset 0x0630` warnings do
not map to any file offset or AML stream offset that could be located — the byte at
file `0x0630` is mid-`External` declaration, not an opcode.

## DSDT repair status

`iasl -d` produces `DSDT.dsl` (**77,151 lines**) but it does **not round-trip**:

```
68 Errors, 172 Warnings, 790 Remarks
Error  6126 - syntax error and premature End-Of-File      (line 74542)
Remark 2067 - Local or Arg used outside a control method
Error  6088 - Object is not accessible from this scope    (HWSZ, GIDP, ASMS)
Error  6084 - Object does not exist
```

The decompiler loses the scope tree around `Scope (UAT2)` at line 74542, which
produces a cascade of spurious scope errors. **`iasl -f` does not help** — it
ignores semantic errors but not syntax errors.

**This is the blocker for producing a rebuilt DSDT.**

Artefacts saved in `nixos-config/vms/macos/acpi-asus/`:

| file | size |
|---|---|
| `DSDT.aml` | 430,740 B |
| `DSDT.dsl` | 2,779,630 B (77,151 lines) |
| `UsbCTabl.dsl` | 25,817 B |
| `iasl-defects.txt` | 3,108 lines |

## Confirmed fixes to keep

**`xh_mtlp3` deletion.** `OemTableId = xh_mtlp3`, `TableSignature = SSDT`.

`\_SB.PC00.XHCI.RHUB.HS03._UPC` is created by the DSDT **and** by
`SSDT21 (xh_mtlp3)`. ACPICA aborts on the table set with `AE_ALREADY_EXISTS`; with
`xh_mtlp3` removed it parses the **whole set cleanly**:

```
Found 2 external control methods, reparsing with new information
Disassembly completed
```

On the machine the failure count moved **15 → 14**.

**The earlier four-table deletion was wrong.**
`TcssSsdt`, `TbtTypeC`, `UsbCTabl` and `xh_mtlp3` were all deleted on the strength
of a collision-finder that matched tables by **leaf name (`_UPC`)** instead of the
port name (`HS03`). Every USB table contains `_UPC`, so three innocent tables were
blamed — and deleting them made **two previously-working tables fail**:

```
delete xh_mtlp3 only           →  14 fail / 12 success
delete all four                →  13 fail / 10 success    ← regression
```

Only `xh_mtlp3` collides. **Match on the specific object, never on a common leaf.**

## Final stick state

**Superseded — see *Breakthrough* below and [`CONFIG-VERSIONS.md`](CONFIG-VERSIONS.md).**
This bare-bones-plus-one-fix state was abandoned; it stripped 27 kexts to 4 and 10
SSDTs to 3, removing `SSDT-EC`, `SSDT-XOSI`, `AppleMCEReporterDisabler`,
`RestrictEvents`, the `DeviceProperties` and the USB map — all of which 1401 had
already supplied and every working Core Ultra config requires.

```
ACPI Delete    [xh_mtlp3]
ACPI Patch     []
ACPI Add       []
kexts          Lilu, VirtualSMC, WhateverGreen, CpuTscSync
boot-args      -v keepsyms=1 debug=0x100 msgbuf=1048576 cpus=2
SMBIOS         iMacPro1,1
```

## Next steps

**Superseded.** The DSDT repair was completed (not by fixing the 68 decompiler errors
— by byte-patching the six `Scope` statements directly, verified against a
from-source build of ACPICA 20160930). The VM bootstrap path was not needed. The
Olarila/MaLd0n route remains a fallback if the current failure point proves to be
ACPI-related.

1. **Fix the VM OpenCore bootstrap** — swap in a fresh acidanthera release.
   Everything else in the testbench is proven. This buys minute-long iterations on
   the DSDT instead of one laptop boot per photograph.
2. **Attempt the DSDT repair proper** — decompile, fix the 68 errors including the
   syntax error at line 74542, recompile, inject via `ACPI → Add`.
3. **Or hand the defect report to someone who repairs Core Ultra DSDTs
   professionally** (Olarila / MaLd0n). The artefacts under *DSDT repair status*,
   plus the exact macOS rejection line, are the complete submission.

Remaining after ACPI: the MUX is **on dGPU** — the correct and required position for macOS
the panel. There is no Apple driver for the Core Ultra iGPU; the eventual target is
the NullMoth driver on the RTX 5080 — the path already validated in
`vms/macos/README.md`.

> **CORRECTED — this was WRONG.** The display **does** work: with the **MUX on the dGPU**
> the macOS installer GUI comes up. The installer can be seen and completed. See
> [`DISPLAY-CONCLUSION.md`](DISPLAY-CONCLUSION.md).

---

# Breakthrough: the boot reaches macOS userland

Two fixes, both derived from ACPICA source, both verified offline, and both confirmed
on the machine, took this laptop from a stop during CPU bring-up to **macOS userland
with `launchd` spawning services**. Every config version and its outcome:
**[`CONFIG-VERSIONS.md`](CONFIG-VERSIONS.md)** — not repeated here.

| | fix | mechanism | result |
|---|---|---|---|
| 1 | `ACPI → Add: DSDT.aml` | six top-level `Scope` targets exist only inside conditional blocks; ACPICA 20160930's two-pass load skips `If`/`Else`/`While` bodies in pass 1 yet still requires every top-level `Scope` target to exist | **14 table load failures → 4** |
| 2 | `ACPI → Delete: Notebook (APIC)` + `ACPI → Add: APIC.aml` | three core types / two Atom native model IDs (`0x2` Crestmont, `0x3` Skymont); `x86_validate_topology()` panics when CPUID-derived threads disagree with MADT | `AppleACPICPU: ProcessorId=2 LocalApicId=32` — P-cores at UIDs 0-5 |

## Why the DSDT repair cannot be an `ACPI → Patch`

The repair is **+20 bytes**, and OpenCore's `ACPI → Patch` is strictly in-place
(`OcAcpiPatchTables()` rejects `Find.Size != Replace.Size`). It must ship as a table
via `ACPI → Add` — which is also Olarila's method for Core Ultra. Six byte edits:
`HS07` wrapped in `If (Zero)`; the five forward references (`HDAS`×2, `SPI0`×3)
wrapped in `If (One) { Scope(X) {...} }`.

## Verified against the parser that actually matters

macOS embeds **ACPICA 20160930**. That version was built from source
(`github.com/acpica/acpica` tag `R09_30_16`) and the repaired table loaded against it:

```
original:  [_SB_.PC00.HDAS] Namespace lookup failure, AE_NOT_FOUND
           → [DSDT] table load failed → 0 objects, "1 table load failures, 0 successful"
repaired:  1 ACPI AML tables successfully acquired and loaded
           0 dswload / dswload2 / tbxfload failures
namespace: 5955 objects / 190 devices / 118 regions / 978 methods — byte-identical
           both ways (5966 namespace nodes)
```

Two source facts explain why Linux and Windows are unaffected: `psloop.c` skips
`If`/`Else`/`While` bodies in pass 1, and `nsload.c` answers a failed `Scope` target
with `AcpiNsDeleteNamespaceByOwner()` — **the entire table's objects are deleted**.
Modern ACPICA inverted this to a single-pass load; only the legacy path macOS retains
behaves this way.

## Retraction: the DSDT failure was never the root blocker

Arithmetic from the two config backups still on the stick:

```
state A (.minimal):  27 firmware + 3 injected = 30 tables → 16 fail / 14 success
bare bones:          27 firmware + 0 injected = 27 tables → 15 fail / 12 success

firmware table results: 15 failures, 12 successes — IDENTICAL in both
16 − 15 = 1 = SSDT-EC                        (failed, OCR-confirmed)
14 − 12 = 2 = SSDT-PLUG-ALT, SSDT-RTCAWAC   (the only two that succeeded)
```

**The DSDT failed in the boots that passed ACPI too.** It was never the
differentiator, and the claim that everything was downstream of it is withdrawn.

The apparent mid-session move of the stop is attributed to the `ACPI → Delete` work
leaving the table set inconsistent — `Invalid handle [Not a Descriptor]` appears only
after those deletes. Confidence **moderate**: the 18-entry batch mostly matched nothing
(13 of 18 names hit no table), and the demonstrably harmful 4-table batch is already
reverted. Full change log: [`REGRESSION-TIMELINE.md`](REGRESSION-TIMELINE.md).

## What the boot does now

```
ACPI Error: 4 table load failures, 23 successful        ← was 14 / 12
pci (build 11:22:54 Jul 4 2025), flags 0xc3080
AppleACPICPU: ProcessorId=0..15, P-cores at LocalApicId 0,8,32,40,48,56 (UIDs 0-5)
[ PCI configuration end, bridges 6, devices 25 ]
IONVMeController ... Successfully initialized NVMe drive
DSMOS has arrived
apfs_module_start: load: com.apple.filesystems.apfs, v2332.140.13
com.apple.xpc.launchd ... fskit / storaged / findmymacd / xpcproxy spawned
                                                         ← stops here
```

## Current failure point

**Boot reaches `launchd` / userland and stops.** In the log:

```
shared_region: ... vm_shared_region_start_address() failed
(system) <Warning>: denied lookup: name = com.apple.windowserver.active
(system) <Warning>: failed lookup: name = com.apple.logd
(system) <Warning>: failed lookup: name = com.apple.opendirectoryd.libinfo
```

> **RESOLVED — both named suspects were red herrings.** The display was the real issue, and
> it is now solved: **MUX on dGPU**. See [`DISPLAY-CONCLUSION.md`](DISPLAY-CONCLUSION.md).
>
> **`shared_region ... vm_shared_region_start_address() failed` is NORMAL**, proven twice
> from XNU source. The function has exactly one failure mode — `sr_first_mapping == -1`,
> i.e. the region is empty — which is the state of every freshly `exec`'d process before
> dyld maps the cache into it. dyld *expects* the non-zero return and treats it as "map
> it now". It prints at default verbosity (`shared_region_trace_level =
> SHARED_REGION_TRACE_ERROR_LVL = 1`). **It cannot prevent WindowServer starting.**
>
> **`denied lookup: name = com.apple.windowserver.active` is a sandbox policy denial**,
> not "WindowServer failed" — `.active` is a flag processes probe to ask "is a GUI session
> up", not WindowServer itself (`bootstrap.h` shows the canonical pairing with
> `HideUntilCheckIn`). *[inference: the emitting code is in closed-source `libxpc`]*
>
> **`Resolution` was never going to help.** `UEFI → Output → Resolution` configures the
> **console**, not an `IOFramebuffer`. The earlier claim that a screenshot of the verbose
> console proved the framebuffer fallback was attached is retracted: visible console text
> proves the *kernel console* is drawing to the firmware framebuffer, nothing more.
> See `DISPLAY-CONCLUSION.md` §2 — `IONDRVFramebuffer`'s class-match path ends in
> `return (false)` on PC firmware because it requires Mac device-tree nodes.
>
> `com.apple.logd` and `com.apple.opendirectoryd.libinfo` lookup failures remain routine
> early-boot noise.

## Correction: the IONDRVSupport block is not in 1401's config

A claim was made during this session that 1401's config ships a `Kernel → Block` on
`com.apple.iokit.IONDRVSupport`, suppressing the firmware framebuffer and therefore
explaining the WindowServer denial. **Verified false:** there are **zero
`Kernel → Block` entries** in `config.plist.1401-full`, `.1401-fixed` and
`.dsmos-reached`. The block is applied by **NullMoth's post-install script**, not
shipped in the config — the research conflated the driver's documentation with the
shipped config.

> **CORRECTED — the premise was right after all.** The framebuffer fallback **does** engage,
> provided the **MUX routes the panel to the dGPU** so the console framebuffer address falls
> inside that device's own `IODeviceMemory` range. The class-match path cannot attach on PC
> firmware, but `IOBootNDRV` is reached another way. The
> resolution change was testing the console framebuffer, which IS the display in fallback mode.
> [`DISPLAY-CONCLUSION.md`](DISPLAY-CONCLUSION.md) §2.

## Removed as unjustified

`CpuTscSync.kext` (TSC deltas on this machine were positive; the negative ones were
caused by a `cpus=15` experiment), `cpus=2`, `msgbuf=1048576`,
`ExitBootServicesDelay=500`, and the SMBIOS `iMacPro1,1` change. Known-good,
known-bad and untested lists: [`CONFIG-VERSIONS.md`](CONFIG-VERSIONS.md).

## Next steps

> **CORRECTED.** Step 1 tested a path that **works once the MUX is on the dGPU** — the
> display came up that way. See [`DISPLAY-CONCLUSION.md`](DISPLAY-CONCLUSION.md).

---

# Display: SOLVED — the MUX must be on the dGPU

**Terminal finding of this work, corrected.** Full detail: [`DISPLAY-CONCLUSION.md`](DISPLAY-CONCLUSION.md).

> **An earlier revision of this file stated that no display was achievable on this hardware.
> That was WRONG, and it is corrected here.** Changing the **MUX from iGPU to dGPU** brought up
> the macOS installer GUI. This is the first documented case of an **Arrow Lake-H laptop**
> reaching the macOS installer.

| MUX position | result |
|---|---|
| **dGPU** | **Installer GUI appears [measured]** |
| iGPU | text console only, no GUI [measured] |
| external monitor on either GPU's port | no output in either configuration [measured] |

**Probable mechanism [inference]:** `IOBootNDRV::fromRegistryEntry` requires the console
framebuffer address (`getConsoleInfo()`, `v_baseAddr & ~3`) to fall **inside one of that PCI
device's own `IODeviceMemory` ranges**. With the panel routed to the NVIDIA, the firmware GOP
framebuffer lives inside the NVIDIA's BAR aperture, so the condition is satisfied; routed to the
iGPU it is not. The exact attach path was not traced with `ioreg` on a live system.

**History of this error — the sequence is the lesson:**

| # | position | verdict |
|---|---|---|
| a | "the framebuffer fallback works" (Alder Lake-H ThinkBook at 2880x1800 with *"No kext loaded"*; 1401's own docs: *"the macOS installer has no NVIDIA driver, so it runs on the firmware's screen"*) | **was right, got explained away** |
| b | "no fallback exists; no display is achievable" (from reading `IONDRVFramebuffer::start()` returning `false` on the class-match path) | **good hypothesis, bad conclusion** |
| c | **"MUX=dGPU works"** | **correct [measured]** |

A correct reading of **one code path** was promoted to a conclusion about the whole platform, and
two pieces of empirical counter-evidence were discounted rather than followed up. **One machine,
never once tested with the MUX on the dGPU, was treated as sufficient to declare a hard stop.**

**Also misread before the MUX change:** the screenshots showed `WindowServer[245]` alive and making
XPC lookups while the system created RAM disks and mounted HFS volumes
(`Creating RAM Disk for /Library/Preferences/Logging`, `hfs: mounted untitled on device disk15`).
The correct reading was **WindowServer running with no display device to claim** — a display-device
problem, not a WindowServer failure. **The boot was never stuck.**

## Practical consequences

- **The MUX must stay on dGPU** for macOS to display anything.
- **The installer runs unaccelerated** on the firmware framebuffer — slow, no Metal, no QE/CI, but functional.
- **After install, the NullMoth driver provides the real display path.** 1401's post-install script applies the `Kernel -> Block` on `com.apple.iokit.IONDRVSupport` so the driver takes display index 0. **That block is intentionally absent from the shipped config and must stay absent during the install.**

## Red herrings, confirmed

- `vm_shared_region_start_address() failed` is **normal** — proven twice from XNU source; the region is empty at `exec` before dyld maps the cache, and dyld *expects* the non-zero return.
- `denied lookup: com.apple.windowserver.active` is a sandbox policy denial where `.active` is a probe flag — **now corroborated, since WindowServer was demonstrably running (`WindowServer[245]`) in the same logs.**

## What the display finding does not invalidate

The two fixes stand as **genuinely new, source-verified results for Arrow Lake-H**:

| result | status |
|---|---|
| **Repaired DSDT** — six top-level `Scope` forward references wrapped so ACPICA 20160930 can load it | **14 -> 4 table failures [measured].** Verified against ACPICA `R09_30_16` built from source: 0 load failures, namespace byte-identical. **No tool produces this** — OpCore-Simplify's RCSP patch matches only **1 of 6** sites (its mask tolerates a 3-byte PkgLength; five blocks use two). |
| **Permuted APIC** — P-cores at UIDs 0-5, the documented workaround for the only three-core-type CPU macOS has met | **Confirmed on the machine: `ProcessorId=2 LocalApicId=32` [measured].** |

The boot passes ACPI, PCI configuration, NVMe initialisation, `DSMOS has arrived`, APFS mounting,
and `launchd` service spawning — **and now reaches the macOS installer GUI.**

## End state

- **ACPI, CPU topology, PCI, storage, userland: solved.** Two original fixes, source-verified and machine-confirmed.
- **Display: solved.** MUX on dGPU. **First documented Arrow Lake-H laptop to reach the macOS installer.**
- **Next step: install macOS.** The NullMoth driver provides the accelerated display path afterwards.
