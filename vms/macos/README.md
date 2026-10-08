# macOS guest

A QEMU/KVM macOS 15 guest tracked in nix like the Windows VMs: the domain XML lives at
`vms/macos/macos.xml` and is registered through
`modules/hardware/virtualization.nix`.

**The NullMoth NVIDIA driver works in this guest.** GPU passthrough is configured, the
driver places its own 16 GiB BAR, and the VRAM budget is 8 GiB. For the current setup
recipe see **[WORKING-RECIPE.md](WORKING-RECIPE.md)**.

Nothing here is pinned to a macOS release. The installer media currently holds one Apple
recovery build (`082-33203`), and swapping `BaseSystem.img` for a newer recovery image is
the only step a newer release would need.

## Documentation in this directory

| file | what it is |
|---|---|
| **[WORKING-RECIPE.md](WORKING-RECIPE.md)** | **the current, verified setup recipe — start here** |
| [DRIVER-INSTALL-NOTES.md](DRIVER-INSTALL-NOTES.md) | investigation history: reasoning, measurements, falsified hypotheses, dead ends |
| [UPSTREAM-REPORT.md](UPSTREAM-REPORT.md) | findings written for the driver author |
| [RECOVERY-STATE.md](RECOVERY-STATE.md) | pre-reboot state snapshot and recovery notes |
| [DEBUG-HISTORY.md](DEBUG-HISTORY.md) | earlier debugging log |

`bench.sh`, `dragload.m`, `surfbench.m`, `shaderbench.m` are the measurement harness
(guest copies live in `~/nvmtltest/`). `nullmoth-desktop.sh`, `setup-macos.sh` and
`shrink-gpu-bar.sh` are helpers.

## What is provisioned

| Piece | Path | Notes |
|---|---|---|
| Guest disk | `/var/lib/libvirt/images/macos.img` | 1 TiB **thin** qcow2, same `default` pool as the win11 VMs |
| OpenCore | `~/OSX-KVM/OpenCore/OpenCore.qcow2` | bootloader; supplies AppleSMC + board-id |
| Recovery media | `~/OSX-KVM/BaseSystem.img` | Apple recovery build `082-33203`, raw 3.2 GB |
| Firmware | `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` | OVMF from nixpkgs |
| NVRAM | `/var/lib/libvirt/qemu/nvram/macos_VARS.fd` | created on first boot |

Bring it up with:

```sh
sudo ./vms/macos/setup-macos.sh     # idempotent; creates the disk, defines the domain
virsh -c qemu:///system start macos --console
```

Then in the OpenCore picker: Disk Utility -> erase the large "sata" disk as **APFS** ->
install macOS. Several reboots; OpenCore auto-selects the installer then the installed
volume.

## GPU passthrough — configured, with one non-obvious requirement

The RTX 5080 Max-Q (`10de:2c59`, mobile GB203M) is passed through, and
`intel_iommu=on iommu=pt` is set in `modules/hardware/virtualization.nix`.

**The GPU must sit behind a PCIe root port, and QEMU must not advertise ACPI hotplug for
PCI bridges.** Without this, macOS sees the card in config space and then assigns it no
resources at all — roots ports publish zero-size `ranges`:

```xml
<qemu:arg value='-global'/>
<qemu:arg value='ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off'/>
```

With it, macOS resources the device, the driver's `placeLargeBar1()` gets the parent
bridge it requires, and the guest GPU becomes usable. See
[WORKING-RECIPE.md](WORKING-RECIPE.md) for the full set of steps, including resizing the
host BAR to 16 GiB.

`<video>` must be `none`, and USB hostdevs belong on an XHCI controller.

## Caveats worth knowing before chasing bugs

1. **Laptop MUX.** On this ASUS the dGPU is wired to the internal panel through a MUX.
   The external monitor on the card's DP-1 works; confirm the display path before
   concluding a driver bug.
2. **RTX 5080 Max-Q (`10de:2c59`) is not a target the NullMoth package was tested on** —
   upstream tested an RTX 5060 (`2d05`). It works here regardless.
3. **`NVRM.kext` cannot be built from public sources.** Verified three ways: `build/`
   emits only NVAccel/NVRMAGDC/plugin/translator/NVK; the public
   `open-gpu-kernel-modules` has no Darwin support; and the scripts require unpublished
   artifacts (`build-nvrm.sh`, `libnvkernel.a`, `$NV/_out/Darwin_x86_64/compile_cmds.sh`).
   `destroyScanoutResource`/`setupScanout` are headers only in the public tree.
   **So the display bugs documented in the recipe cannot be patched from outside** and
   have to go upstream.
4. **Run games windowed/borderless.** A fullscreen display-mode transition wedges the
   scanout; recovery is `sudo killall -9 WindowServer` (see the recipe's recovery ladder).
