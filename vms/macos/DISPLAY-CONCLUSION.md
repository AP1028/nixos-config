# Display: SOLVED — the MUX position is the enabling condition

**Terminal finding, corrected.** An earlier revision of this file stated that no display was
achievable on this hardware. **That was wrong.** The macOS installer GUI comes up on this
Arrow Lake-H laptop. The enabling condition is the **MUX position: it must be on the dGPU.**

This is the first documented case of an Arrow Lake-H **laptop** reaching the macOS installer.

Cross-reference: [`CONFIG-VERSIONS.md`](CONFIG-VERSIONS.md) for the config inventory,
[`BARE-METAL.md`](BARE-METAL.md) for the bring-up record.

Evidence markers: **[MEASURED]** observed on this machine · **[SRC]** read from Apple's
published source · **[INFER]** reasoning from source, not traced in a live system ·
**[REPORTED]** from a third party.

---

## 1. The finding

| | |
|---|---|
| **MUX → dGPU** | **Installer GUI appears. Works.** **[MEASURED]** |
| **MUX → iGPU** | Text console only, no GUI. **[MEASURED]** |
| External monitor on either GPU's port | No output in either configuration. **[MEASURED]** |

**The MUX must remain on the dGPU for macOS to have a display.** The user's reasoning before
testing was exactly right: *"flick mux to dGPU, so it behaves like a desktop with nvidia gpu,
running on framebuffer"* — a dGPU-driven laptop is topologically a desktop, which is the
configuration where unsupported-GPU macOS installs are known to work.

## 2. Probable mechanism **[INFER]**

`IOBootNDRV::fromRegistryEntry` — the genuine internal fallback inside `IONDRVFramebuffer` —
requires the console framebuffer address (`getConsoleInfo()`, `v_baseAddr & ~3`) to fall
**inside one of that PCI device's own `IODeviceMemory` ranges** **[SRC]**.

| MUX position | console framebuffer lives… | condition |
|---|---|---|
| **dGPU** | inside the **NVIDIA's BAR aperture** | **satisfied → fallback engages** |
| iGPU | inside the Intel's aperture, on a device that never starts | not satisfied |

That would explain both observations at once, including why an **external** monitor produced
nothing — the fallback attaches to the device owning the *internal panel*, not to an
arbitrary output.

**Marked [INFER] deliberately:** the observed facts are that MUX=dGPU works and MUX=iGPU does
not. The exact attach path was not traced with `ioreg` on a live system. The source analysis
described `IONDRVFramebuffer`'s class-match path correctly, but the machine found a path that
analysis did not trace.

## 3. History of this error — recorded, not hidden

The session went through three positions on this. The sequence is the lesson.

| # | position | basis | verdict |
|---|---|---|---|
| a | "Framebuffer fallback works on unsupported-GPU laptops" | Alder Lake-H ThinkBook at 2880×1800 with *"No kext loaded"*; 1401's own docs: *"the macOS installer has no NVIDIA driver, so it runs on the firmware's screen"* | **was right, and got explained away** |
| b | "No fallback exists; no display is achievable" | Source reading of `IONDRVFramebuffer::start()` returning `false` on the class-match path | **good hypothesis, bad conclusion** |
| c | **"The display works with MUX=dGPU"** | **The installer GUI came up [MEASURED]** | **correct** |

**What went wrong in (b):** a correct reading of one code path was promoted to a conclusion
about the whole platform, and two pieces of empirical counter-evidence were discounted
rather than followed up. The vanishingly small sample — *one* machine, never tested with the
MUX on the dGPU — was treated as sufficient to declare a hard stop.

**Also misread before the MUX change:** the screenshots showed `WindowServer[245]` alive and
making XPC lookups, while the system created RAM disks and mounted HFS volumes
(`Creating RAM Disk for /Library/Preferences/Logging`, `hfs: mounted untitled on device
disk15`). The correct reading was **WindowServer running with no display device to claim** —
a display-device problem, not a WindowServer failure. The boot was never stuck.

## 4. Practical consequences

- **The MUX must stay on dGPU** for macOS to display anything. Moving it back to the iGPU
  removes the display.
- **The installer runs unaccelerated** on the firmware framebuffer — slow, no Metal, no
  QE/CI, but functional. Resolution is whatever the firmware/OpenCore presents.
- **After installation the NullMoth driver provides the real display path.** 1401's
  post-install script is what applies the `Kernel → Block` on
  `com.apple.iokit.IONDRVSupport`, so the driver takes display index 0 instead of the
  fallback. **That block is intentionally absent from the shipped config** — it must not be
  present during the install. (An earlier claim that 1401's config blocks it was checked and
  is false: zero `Kernel → Block` entries in every shipped config version.)

## 5. Red herrings — confirmed, do not retry

### `shared_region: ... vm_shared_region_start_address() failed` — **NORMAL**

`vm_shared_region_start_address()` has exactly one failure mode — `sr_first_mapping == -1`,
commented `/* shared region is empty */` → `KERN_INVALID_ADDRESS` **[SRC]**. That is the state
of every freshly `exec`'d process before dyld maps the cache. dyld **expects** the non-zero
return **[SRC]**, and it prints at default verbosity
(`shared_region_trace_level = SHARED_REGION_TRACE_ERROR_LVL = 1`) **[SRC]**. One line per
spawned process is normal. It cannot prevent WindowServer starting.

### `denied lookup: name = com.apple.windowserver.active` — **a probe flag, now corroborated**

Not "WindowServer failed". `.active` is a **flag processes probe** to ask "is a GUI session
up"; `bootstrap.h` shows the canonical pairing `com.apple.windowserver` +
`com.apple.windowserver.active` with `HideUntilCheckIn` **[SRC]**. **This is now corroborated
empirically**: WindowServer was demonstrably running (`WindowServer[245]`) in the very logs
that contained these denials. The denial is a sandbox policy rejection with no bearing on
WindowServer's liveness. The exact emitting code is in closed-source `libxpc`, so the
classification remains **[INFER]** — but the machine has since confirmed the conclusion.

## 6. What does NOT help — corrected

| attempt | verdict |
|---|---|
| **External monitor on either GPU's port** | No output in either MUX configuration **[MEASURED]**. The fallback attaches to the internal panel's device. |
| **MUX change** | **This IS the fix — to dGPU.** The earlier revision of this file claimed it changed nothing. It is the enabling condition. |
| `UEFI → Output` settings incl. `ForceResolution` | Console-only; `ForceResolution` requires `OpenDuetPkg`. Not the mechanism — but harmless, and the console framebuffer is what the fallback uses, so resolution still affects the result. |
| Booter quirks | No graphics linkage found. |
| `-wegnoegpu` | Hides GPUs; adds no driver. |
| `debug=0x144` | `0x100 DB_LOG_PI_SCRN` is obsolete in modern XNU `debug.h`; meaningful bits are `DB_HALT 0x1` and `DB_KDP_BP_DIS 0x80`. |

## 7. What this does not invalidate

Both fixes stand as **genuinely new, source-verified results for Arrow Lake-H**:

| result | verification |
|---|---|
| **Repaired DSDT** | Six top-level `Scope` forward references wrapped so ACPICA 20160930 can load the table. **14 → 4 table failures [MEASURED].** Verified against ACPICA R09_30_16 built from source: 0 load-time failures, namespace byte-identical (5955 objects / 190 devices / 118 regions / 978 methods). **No existing tool produces this** — OpCore-Simplify's RCSP patch matches only **1 of the 6** sites. |
| **Permuted APIC** | P-cores at UIDs 0-5, the documented workaround for the only three-core-type CPU macOS has met (P/E/LP-E, two Atom Native Model IDs `0x2` Crestmont and `0x3` Skymont). **Confirmed: `ProcessorId=2 LocalApicId=32` [MEASURED].** |

The boot passes ACPI, PCI configuration, NVMe initialisation, `DSMOS has arrived`, APFS
mounting, and `launchd` service spawning — **and now reaches the macOS installer GUI.**

## 8. End state

- **ACPI, CPU topology, PCI, storage, userland bring-up: solved.** Two original fixes, both source-verified and machine-confirmed.
- **Display: solved.** MUX on dGPU. First documented Arrow Lake-H laptop to reach the macOS installer.
- **Next step: install macOS.** The NullMoth driver provides the accelerated display path afterwards.
