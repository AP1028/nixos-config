# Debug history — SUPERSEDED, kept only as a record

**Do not follow anything in this file.** It is the chronological debugging log
from before the driver worked, and several of its conclusions are now known to
be wrong (for example "the GPU enumerates but macOS assigns it no BARs",
"shrink BAR1 DID NOT WORK", and the x-no-mmap workaround). The current,
correct configuration is in [DRIVER-INSTALL-NOTES.md](DRIVER-INSTALL-NOTES.md).

It is kept because the *methods* are reusable — how the non-canonical BAR
address was found, how the host IOMMU refusal was identified, and the list of
things that were tried and did not help.

---

## Superseded analysis (kept for the record)

## Passthrough: status and analysis

**Passthrough is currently REMOVED from `macos.xml`** because it crashes the
domain. The GPU's physical BARs, from `lspci -vvs 01:00.0` on the host:

```
Region 0: 64M   (32-bit, non-prefetchable)
Region 1: 16G   (64-bit, prefetchable)     <- the problem
Region 3: 32M   (64-bit, prefetchable)
Region 5: 128B  (I/O)
Expansion ROM: 512K [virtual] [disabled]

Capabilities: [134 v1] Physical Resizable BAR
    BAR 1: current size: 16GB, supported: 64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB
```

### Status: GPU is now ENUMERABLE, but QEMU crashes on the 16 GB BAR

Two separate things were wrong, and only one is fixed.

**Fixed — placement.** macOS defers all PCIe enumeration when it sees ACPI
hot-plug methods, which QEMU emits for every root port. Behind a root port the
card was invisible:

```
Bus 1, device 0, function 0: 10de:2c59
   IRQ 0, pin A
   BAR0/BAR1/BAR5: (not mapped)
```
and no `10de` anywhere in `ioreg`, though `ioreg` did list 30 PCI devices.
On bus 0 the same card comes up properly:

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10
   BAR0: 32 bit memory at 0x80000000  [0x83ffffff]
   BAR1: 64 bit prefetchable at 0x800000000 [0xbffffffff]
   BAR5: I/O at 0x6000 [0x607f]
```

So bus 0 is required, exactly as it was for the NIC. Same root cause.

**Not fixed — QEMU crashes before macOS boots.** With the hostdev present:

```
kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
  start=0x8508000000000000, size=0x400000000: Invalid argument
kvm_set_phys_mem: error registering slot: Invalid argument
shutting down, reason=crashed
```

`0x8508000000000000` is the 64-bit BAR base `0x850800000` reinterpreted as a
64-bit base — an address-placement overflow in QEMU, not a macOS fault.

Ruled out by experiment (both had no effect on the crash):

| Attempt | Result |
|---|---|
| `-cpu ...,phys-bits=40` | QEMU warns `Host physical bits (46) does not match phys-bits property (40)`; crash unchanged |
| `-global q35-pcihost.pci-hole64-size=137438953472` | Confirmed present in QEMU's argv (log line 1348); crash unchanged |

### Next lever: shrink BAR1 — ATTEMPTED, DID NOT WORK

**Result: the shrink was rejected by the kernel.** Recorded so this is not
retried blindly.

`resource1_resize` advertises `0000000000007fc0` — bits 6..14, i.e.
64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB — matching `lspci`. The file is
writable. Writing a new size fails regardless of format:

```
pci 0000:01:00.0: Failed to resize BAR 1: -EINVAL
```

Tested: `1073741824` (1 GiB decimal), `0x40000000` (1 GiB hex), `14` (bit index).
All rejected. The device was correctly unbound first — no `-EBUSY`, which is what
an assigned resource or enabled memory decode would have produced.

Reading `drivers/pci/setup-res.c` (v6.12) shows `-EINVAL` can only come from one
place:

```c
sizes = pci_rebar_get_possible_sizes(dev, resno);
if (!sizes)               return -ENOTSUPP;
if (!(sizes & BIT(size))) return -EINVAL;      /* <- the only -EINVAL */
```

So the size set the kernel validates against does **not** match what the sysfs
mask reports. That is a kernel/hardware disagreement on this device, not a
formatting mistake. (The subsequent `pci_rebar_set_size()` can also fail on
hardware refusal, which would surface as its own error code.)

Net effect: **BAR1 cannot be shrunk from Linux on this kernel (7.2.8).** The card
is unharmed — BAR1 is still `0x6000000000`–`0x63ffffffff` (16 GiB) and it rebinds
to `vfio-pci` cleanly.

### ROOT CAUSE FOUND: the host IOMMU refuses to map the 16 GiB BAR

The crash is **not** guest-side placement. The full log sequence is:

```
vfio_container_dma_map(0x59ebfd150440, 0x382800000000, 0x400000000, 0x7d1240000000) = -22 (Invalid argument)
0000:01:00.0: PCI peer-to-peer transactions on BARs are not supported.
kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
  start=0x8508000000000000, size=0x400000000: Invalid argument
shutting down, reason=crashed
```

Read in order: `size=0x400000000` is **exactly 16 GiB, i.e. BAR1**. QEMU asks the
host IOMMU to map BAR1, the kernel's VFIO **IOMMU** returns `-22 (EINVAL)`, and
that failure then corrupts the memory-region registration. The bogus
`start=0x8508000000000000` is the *symptom*, not the cause. QEMU aborts.

This also explains why every guest-side knob failed: none of them change what the
host IOMMU is asked to map.

### WORKAROUND THAT WORKS: `x-no-mmap=on`

| flag | result |
|---|---|
| *(none)* | **crashes** — `vfio_container_dma_map(...) = -22`, then `kvm_set_user_memory_region ... size=0x400000000 (16 GiB)`, domain aborts |
| `vfio-pci.x-no-kvm-intx=on` (OSX-KVM's own flag) | **crashes identically** |
| **`vfio-pci.x-no-mmap=on`** | **boots.** Domain survives, macOS enumerates the card |

`x-no-mmap` stops QEMU mmapping the BAR, so it traps MMIO in userspace instead
of registering a KVM memory slot for the 16 GiB region — that registration was
the failing path.

Applied as a `-global` (not `-set`, which is processed during early option
parsing before `-device` instances exist, and so cannot reference them by id):

```xml
<qemu:arg value='-global'/>
<qemu:arg value='vfio-pci.x-no-mmap=on'/>
```

The two flags are unrelated: `x-no-mmap` concerns **MMIO/BAR mapping**,
`x-no-kvm-intx` concerns **INTx interrupt injection**. Only the former addresses
this failure.

### Verified state with the workaround

QEMU reports the card on the root bus with real BARs:

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10, pin A
   BAR0: 32 bit memory at 0x80000000          [0x83ffffff]   valid
   BAR1: 64 bit prefetchable at 0x8508000000000000 [0x85080003ffffffff]   BOGUS
   BAR3: 64 bit prefetchable at 0xf0000000    [0xf1ffffff]   valid
   BAR5: I/O at 0x6000                        [0x607f]       valid
```

macOS enumerates it (the driver's third gate now passes):

```
ioreg: 2 x "vendor-id" = <de100000>
Display: Type GPU, Vendor NVIDIA (0x10de), Device ID 0x2c59, Revision 0x00a1
```

Note `bar='off'` appears as a `rombar=0` key on the QEMU device, so something is
still overriding the ROM BAR despite the element being removed from `macos.xml`.

### OPEN ISSUE: BAR1 is at an invalid address

BAR1 — the 16 GiB VRAM window — is presented at `0x8508000000000000`, which is
not a usable address. That is the same value that previously appeared only in
the crash message; with `x-no-mmap` the domain survives but the address is still
wrong. Enumeration succeeding does **not** prove MMIO works: the card is visible
and bound to `IONDRVFramebuffer`, but nothing has yet read GPU registers through
it. Whether the driver can actually drive the card with a bad BAR1 is unknown and
is the next thing to establish.

Also noted: the device is **not** flagged built-in (`"built-in" = <00>`), and
macOS classifies it as `"display"` and attaches it to
`IONDRVFramebuffer/AGPM`.

### Things tried, all ineffective (do not repeat)

| Attempt | Result |
|---|---|
| hostdev behind a root port (bus 0x06) | never enumerated (IRQ 0, BARs unmapped) — that part was real, fixed by bus 0 |
| `-cpu ...,phys-bits=40` | QEMU warns host is 46-bit; crash identical |
| `-global q35-pcihost.pci-hole64-size=137438953472` | confirmed in QEMU argv; crash identical |
| `-cpu ...,phys-bits=46,+pdpe1gb` | Proxmox's documented precondition for BARs > 16 GB; **crash identical** |
| shrink BAR1 to 1 GiB via `resource1_resize` | kernel returns `-EINVAL`; BAR cannot be shrunk |
| removing `<rom bar='off'/>` | no effect |

The Proxmox precondition work (bug #7711) is real and worth knowing — EDK2 caps
MMIO at `2^(phys-bits-3)`, so `phys-bits` governs BAR space and not just RAM —
but it is **not** our blocker. We fail earlier, in the host IOMMU.

### CONCLUSION: the GPU enumerates but macOS assigns it no BARs

Measured in the guest with `mmio-probe.py` and `ioreg`. The GPU node has **no
memory resources at all**, while its own audio function on the same card has
them:

| node | `IODeviceMemory` | `assigned-addresses` |
|---|---|---|
| `S20@40000` — GPU `10de:2c59` | **0 (none)** | **absent** |
| `S21@4,1` — audio `10de:22e9` | present, `address=2242461696 length=16384` | present |

Identity is correct (`vendor-id de100000`, `device-id 592c0000`,
`class-code 00000300` = VGA, `built-in 00`), and the node carries
`IOPCIResourced = Yes` with the firmware `reg` — but macOS created **no assigned
addresses and no memory objects for any GPU BAR**. No `IONDRVFramebuffer`/AGPM is
created for it either.

Consequence: **`install.sh`'s `ioreg` gate passes while the card is unusable.**
That gate only greps for `vendor-id = <de100000>`. Enumeration does not imply a
usable aperture, and this is the one thing to remember from all of the above: the
gate is satisfied by a card whose memory windows cannot be mapped.

`mmio-probe.py`'s userland map attempt returns `0xe00002c2`
(`kIOReturnUnsupported`) — expected without an entitlement, and it tells us
nothing either way (an `IOPCIDevice` has no user client).

Note on tooling: `/usr/bin/python3` is an Xcode CLT stub, so the probe needs a
real Python and root. `ioreg` alone can read `IODeviceMemory` (it prints decimal
`address`/`length`), which needs neither. The probe's `reg` decoder is **wrong** —
it reports every entry as `config addr=0x0` — so do not trust its BAR decode; the
`IODeviceMemory` section and `ioreg` are the reliable evidence.

### What this means, and the remaining options

The host IOMMU cannot map a 16 GiB BAR for this device. Options, best first:

1. **Disable Resizable BAR in the host BIOS.** The card then exposes a small
   default BAR (typically 256 MB) instead of 16 GiB and the IOMMU map is trivial.
   This is the direct fix for the actual failure, and it matches NullMoth's own
   bare-metal recipe (`ResizeGpuBars=13` = an **8 GB** BAR).
2. **Try a different QEMU version.** 11.1.1 is very new; a regression in vfio
   IOMMU mapping or the `p2p` handling is plausible.
3. **Stop.** The driver remains unproven on this card (developed on an RTX 5060;
   ours is mobile Blackwell), so the remaining work may not pay off.

`shrink-gpu-bar.sh` implements the safe unbind/resize/rebind sequence and is
reusable if the kernel behaviour changes.

## Re-enabling passthrough

Restore these two elements in `macos.xml`, inside `<devices>`:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0' multifunction='on'/>
</hostdev>
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x1'/>
</hostdev>
```

`managed='yes'`, no `<rom>` element, guest bus **0x00** (not a root port), and
`multifunction='on'` on function 0 so the audio function is seen. Then confirm
from the host that QEMU survives and the card shows `IRQ`/mapped BARs, and from
the guest that `ioreg` lists `10de`.

## Recommended order

**Phase 1 and Phase 2 are deliberately separate.** Do not arm the driver
(`nvfb=1 nvaccel=1`) in the same boot that first brings the GPU through: if that
boot fails you cannot tell whether passthrough or the driver caused it. The
hostdevs are already in `macos.xml`; the OpenCore settings are not yet applied.

### Phase 1 — verify passthrough alone (current state)

Boot the domain as it is. The guest should come up on the virtual GPU exactly as
before, now with an unknown NVIDIA display device attached. Confirm:

```sh
ioreg -r -c IOPCIDevice -d 1 | grep -i 'vendor-id.*de100000'   # the card is visible
system_profiler SPDisplaysDataType | head -30                   # listed, likely "no kext loaded"
```

If macOS still boots cleanly and the card is visible, passthrough works. If the
boot hangs, the problem is passthrough, not the driver — and you still have the
virtual GPU plus SSH to recover.

### Phase 2 — arm and install

1. **Apply the guest-side settings** (Route A or B above), then reboot and confirm:
   ```sh
   nvram boot-args
   csrutil status          # expect: disabled
   ```
2. **Only then run `install.sh`.** Gate 3 passes now.
3. Reboot, then verify:
   ```sh
   kmutil showloaded --list-only | grep nullmoth      # expect 4
   system_profiler SPDisplaysDataType | head -20      # expect GeForce + Metal
   ```
4. **Arm the Metal gate** — the accelerator withholds `MetalPluginName` until:
   ```sh
   sudo sysctl -w debug.nvaccelfb=1
   ```
   and `/Library/GPUBundles/nvmtl-allow.txt` is a process allow-list defaulting
   to deny (test apps must be listed, or be named `mtlprobe`/`nvmtltest`/
   `nvmtlrender`).

## Host power note

The GPU is currently bound to `vfio-pci` at boot, so the host is not using it and
passing it through costs nothing. If you would rather leave the card powered down
when not in use, `gpu-off` / `gpu-on` / `gpu-power-status` manage that. The
accelerator's own README notes the driver expects the card **powered on**, so run
`gpu-on` (or leave the vfio-pci default binding) before starting the domain.

## Recovery levers — have these ready BEFORE installing

- **`-nvoff`** — NVRM honours it and leaves the card alone. Add it to boot-args
  to disarm the driver without uninstalling:
  ```sh
  sudo nvram boot-args="... -nvoff"
  ```
- **`install.sh` is safe-ish by construction**: it test-builds the collection
  before writing anything, and writes a numbered backup. If macOS will not boot,
  `/Library/NullMoth/backup-*` plus `uninstall.sh <dir>` is the way back — but
  that needs a bootable system, so keep SSH access working.
- **Keep the virtual GPU.** Do not remove `<video>` from the domain: it is the
  console of last resort if the NVIDIA driver wedges the display, and it is how
  you keep SSH reachable.

## Honest risk assessment

1. **Untested card.** Developed on an RTX 5060 (`2d05`). Ours is `10de:2c59`,
   RTX 5080 Max-Q, mobile Blackwell GB203M. Its NVRM maps the GB20X family and
   the package ships `gsp_ga10x.bin`/`ucodes_ga10x.bin`, so there is a plausible
   path, but mobile Blackwell is outside the tested set. The README says so.
2. **Firmware must be present** at `/Users/Shared/nvfw/nvidia/610.57.04/`.
   `install.sh` copies it, but if the tarball's `pkgroot` layout differs the
   copy will be wrong — verify the four `.bin` files exist after install.
3. **Unsigned kexts need Secure Boot off in the guest.** Ours is already off
   (libvirt picked the non-secure OVMF loader). Do not re-enable.
4. **No display will light up from the passed-through card** unless something is
   plugged into its outputs: the internal panel is wired to the Intel Arc iGPU.
   `nvfbheads=4` may create heads, but that is untested here.
