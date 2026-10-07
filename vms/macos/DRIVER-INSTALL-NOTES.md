# Installing the NullMoth driver — investigation results

What the script does, what it does not do, and the exact settings required.
Derived from `package/install.sh`, the driver's README, and — most usefully —
the maintainer's own working implementation in `app/Resources/nullmoth-setup.sh`.

## Direct answer: script alone is NOT enough

`install.sh` verifies and installs files, then **warns** that it cannot do the
rest. Verbatim from its step 6:

```
step "6. boot-args"
ba=$(nvram boot-args 2>/dev/null | cut -f2-)
for a in nvfb=1 nvaccel=1; do case " $ba " in *" $a "*) ;; *) echo "   NOTE: boot-args lack '$a' — add it in your OpenCore config.plist (see README)";; esac; done
```

It contains no handling of `boot-args`, `csr-active-config`, `ScanPolicy`, SIP,
or Secure Boot. Those must be set separately.

### Its three hard gates

```
[ "$(uname -m)" = x86_64 ]                 || die "Intel/x86_64 only"
v=$(sw_vers -productVersion); [ "${v%%.*}" = 15 ] || die "macOS 15 required"
ioreg -r -c IOPCIDevice -d 1 | grep -q '"vendor-id" = <de100000>' || die "no NVIDIA GPU found on PCI"
```

Gate 3 is the one passthrough unlocks. Gates 1 and 2 already pass.

### What the script actually does, in order

1. Checks the three gates above.
2. `shasum -a 256 -c SHA256SUMS` — refuses on mismatch.
3. **Test-builds the Auxiliary Kernel Collection** into a temp dir and confirms
   all four kexts appear in it. Nothing is written yet. `CHECK=1` stops here.
4. Backs up existing kexts/bundles and the live `.kc` to
   `/Library/NullMoth/backup-<timestamp>`.
5. Copies `NVRM/NVAccel/NVRMFB/NVRMAGDC.kext` → `/Library/Extensions`;
   `NVMTLDriver.bundle`, `NVIDIAShared.bundle`, `nvmtl/` → `/Library/GPUBundles`;
   firmware → `/Users/Shared/nvfw`; fixes ownership/modes.
6. `kmutil create -n aux --volume-root / --allow-missing-kdk ...` to rebuild
   `/Library/KernelCollections/AuxiliaryKernelExtensions.kc`, then re-inspects
   it and dies if any of the four is missing.
7. Warns about missing boot-args.

`uninstall.sh [backupdir]` removes the files and rebuilds the collection, or
restores wholesale from a backup directory if given one.

## The exact settings, verified against 1401

From `app/Resources/nullmoth-setup.sh` — the maintainer's own implementation, so
this is authoritative rather than inferred:

```sh
WANT_ARGS="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80"
DROP_ARGS="nv_disable=1 -wegnoegpu"     # both hide the NVIDIA card from macOS
SIP_BITS=$((0x0A43))
```

Note their implementation **merges** the SIP bits rather than overwriting:
`want=$(( cur | SIP_BITS ))`. If SIP is currently fully enabled (`0x0000`), the
result is exactly `0x0A43`, which is what the README writes as `<430A0000>` —
that literal is the little-endian byte layout of `0x0A43`. In a plist it is the
4 data bytes `43 0A 00 00`, i.e. base64 `QwoAAA==`.

| Setting | Value | Applies to |
|---|---|---|
| `NVRAM → Add → 7C436110-… → boot-args` | `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80` | guest |
| `NVRAM → Add → … → csr-active-config` | data `43 0A 00 00` (`QwoAAA==`) = `0x0A43` | guest |
| `NVRAM → Delete → …` | add `boot-args` **and** `csr-active-config` | guest — so OpenCore rewrites them every boot |
| `Misc → Security → SecureBootModel` | `Disabled` | guest (already is) |
| `Kernel → Block` | add `com.apple.iokit.IONDRVSupport`, `Strategy=Exclude`, `Enabled=true`, `Arch=Any` | guest |
| `UEFI → Quirks → ResizeGpuBars` | `13` | **HOST ONLY** |
| `Booter → Quirks → ResizeAppleGpuBars` | `-1` | **HOST ONLY** |

### Why the BAR settings do not apply to us

`ResizeGpuBars` makes the **host's** UEFI firmware reprogram the physical GPU's
BARs to 8 GB. Inside QEMU the guest sees an emulated root complex and the
passed-through GPU's BARs as exposed by the vfio hostdev; a guest bootloader
cannot reprogram them. Their own README says the *macOS installer* needs the
opposite values (`ResizeAppleGpuBars 0`, `ResizeGpuBars -1`) — i.e. these are
properties of the bare-metal boot, not of macOS. For a VM: skip them, and if
BAR sizing ever matters it is a host OpenCore change, not a guest one.

`IONDRVSupport` blocking is different — it is a macOS kernel-extension policy,
so it does carry over and is worth setting.

## Two routes to apply the guest-side settings

**Route A — edit OpenCore's `config.plist` offline (what the README prescribes).**
Mount `~/OSX-KVM/OpenCore/OpenCore.qcow2` with `qemu-nbd`, patch the ESP's
`/EFI/OC/config.plist`, unmount. Must be done with the VM **shut down**. This
keeps the settings in the bootloader, which is what the driver documents, and
survives anything the guest does to its own NVRAM.

**Route B — set NVRAM from inside the guest** (now possible because SSH works):

```sh
sudo nvram boot-args="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80"
sudo nvram csr-active-config=%43%0A%00%00
sudo reboot
```

Faster, no shutdown needed, but NVRAM-only: on a Mac whose bootloader rewrites
`boot-args` each boot it can be reverted, and it does not set
`SecureBootModel`/`IONDRVSupport` (those are bootloader-side). Use this for a
quick `-nvoff` recovery toggle; use Route A for the real configuration.

Note `csr-active-config` **only takes effect on reboot**, and `csrutil status`
will report SIP disabled only after one.

## RESOLVED — the passthrough works now

The blocker was the **BAR size**, and it is fixable entirely from Linux. No BIOS
change is required, and Resizable BAR can stay enabled on the host.

### The symptom was a non-canonical address

The GPU's BAR1 was presented at **`0x8508000000000000`**, which is not a valid
x86-64 address (outside both the user range `< 0x800000000000` and the kernel
range `>= 0xffff800000000000`). It equals **`0x85080000 << 32`** — a 32-bit MMIO
base written into the *high* dword of a 64-bit BAR, low dword zero. This matches
a known EDK2 bug class in `PcatPciRootBridgeParseBars`, which combines a BAR's
halves with `LShiftU64(UpperValue, 32)` and chooses an aperture from whether the
base is below 4 GiB. It is **not** an intended address.

### The fix: shrink BAR1 from the host

`resource1_resize` takes a **bit index**, not bytes:
`0`=1 MB, `1`=2 MB, … `10`=1 GiB, `11`=2 GiB, **`12`=4 GiB**, `13`=8 GiB.

Measured threshold:

| host BAR1 | guest BAR1 | |
|---|---|---|
| 256 MiB | `0x90000000` | ok |
| 512 MiB / 1 / 2 GiB | `0x800000000` | ok |
| **4 GiB** | `0x800000000` | **ok — largest working** |
| 8 GiB | `0x8508000000000000` | broken |
| 16 GiB | `0x8508000000000000` | broken |

Working sequence (needs the device released first):

```sh
BDF=0000:01:00.0
echo ""        > /sys/bus/pci/devices/$BDF/driver_override           # unpin
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/unbind
echo 12        > /sys/bus/pci/devices/$BDF/resource1_resize          # 4 GiB
echo vfio-pci  > /sys/bus/pci/devices/$BDF/driver_override
echo $BDF      > /sys/bus/pci/drivers/vfio-pci/bind
```

Two traps that made earlier attempts fail misleadingly:

1. **`driver_override` was pinned to `vfio-pci`.** With it set, the kernel
   immediately re-binds the device, so `unbind` fails and the resize returns
   `EBUSY`/`ENODEV` — masking the real error. Clear it first.
2. **Bit index vs bytes.** Writing byte values (e.g. `1073741824`) decodes to bit
   30 and is correctly rejected with `-EINVAL`. That is not a kernel refusal to
   shrink; the kernel does allow shrinking.

Consequence: the domain now boots with **no `x-no-mmap` and no `x-no-kvm-intx`**.
Those workarounds were only ever compensating for the bad BAR, and are removed.

### Resulting guest state

```
Bus 0, device 4, function 0: 10de:2c59   IRQ 10, pin A
   BAR0: 32 bit memory at 0x80000000        [0x83ffffff]
   BAR1: 64 bit prefetchable at 0x800000000 [0x8ffffffff]   4 GiB at 32 GiB
   BAR3: 64 bit prefetchable at 0xf0000000  [0xf1ffffff]
   BAR5: I/O at 0x6000                      [0x607f]
```

No `kvm_set_user_memory_region` or `vfio_container_dma_map` errors. macOS 15.8.1
enumerates the card (`vendor-id de100000`, `device-id 0x2c59`).

### The custom OSX-KVM OVMF is NOT needed

- OSX-KVM's own `macOS-libvirt-Catalina.xml` says so verbatim:
  *"We don't need patched OVMF anymore when using latest OpenCore, stock one is okay"*.
- Tested both with the 4 GiB BAR: **identical result** (`BAR1 = 0x800000000`).
- NixOS's stock OVMF is the better choice: its varstore is correctly paired
  (4 MB code + 528 KB vars), whereas OSX-KVM's pair is mismatched
  (`OVMF_CODE_4M.fd` 3653632 B with `OVMF_VARS*.fd` only 131072 B).
- Their variants exist to pre-set the OVMF preferred resolution
  (`OVMF_VARS-1024x768.fd`, `OVMF_VARS-1920x1080.fd`), per `notes.md`. That is a
  convenience, settable in the OVMF menu, not a requirement.

Kept: `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` + `edk2-i386-vars.fd`.

### Still outstanding

1. **BAR sizing is now automatic — no boot service needed.** `gpu-to-vfio` and
   `gpu-to-host` in `packages/gpu-vfio-scripts.nix` now program BAR1 (4 GiB on
   vfio, 16 GiB back on the host), and `gpu-vfio-status` shows the current size.
   Since `vfio-pci.ids=` is commented out (`virtualization.nix:137`), the GPU
   does **not** bind to vfio at boot — `gpu-to-vfio` is the entry point, so it
   is the natural place for the resize and there is nothing to run at boot.
   *Caveat:* if `vfio-pci.ids=10de:2c59,10de:22e9` is ever uncommented for
   boot-time binding, the BAR would come up at the firmware size (16 GiB) and a
   boot-time resize would then be required.
2. **SMBIOS is `iMac19,1`**; the driver specifies `iMacPro1,1`.
3. **OpenCore patch** still required: `csr-active-config`, `boot-args`,
   `Kernel → Block IONDRVSupport`, `SecureBootModel Disabled`.
4. `WhateverGreen.kext` is loaded; the driver README says to remove its NVIDIA
   patches and `agdpmod=pikera`.

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
