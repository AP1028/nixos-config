# macOS guest (asusg16)

A QEMU/KVM macOS guest, tracked in nix like the Windows VMs: the domain XML
lives at `vms/macos/macos.xml` and is registered through
`modules/hardware/virtualization.nix`.

Nothing here is pinned to a macOS release. The installer media currently holds
one Apple recovery build (`082-33203`), and the NullMoth driver targets the
release in its README "for now" — but neither this domain nor the guest is tied
to that: swapping `BaseSystem.img` for a newer recovery image is the only step a
newer release would need.

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

Then in the OpenCore picker: Disk Utility -> erase the large "sata" disk as
**APFS** -> install macOS. Several reboots; OpenCore auto-selects the
installer then the installed volume.

## Important: the NullMoth driver cannot run here yet

`nvidia-macos-driver` is a driver for **physical NVIDIA GSP-generation GPUs**.
It cannot do anything in this VM as configured:

- Its kexts match a real NVIDIA PCI device (`IOPCIPrimaryMatch` = vendor
  `0x10de`). QEMU's `vmware-svga` / `virtio-gpu` are VMware/virtio devices, so
  `NVRM.kext` never probes and no `IOAccelerator` is created.
- The Metal plugin is only reachable through that accelerator. On a virtual GPU,
  macOS uses `AppleParavirtGPU`/`vmwgfx` instead; `NVMTLDriver.bundle` is never
  loaded.
- `NVRM`'s GSP firmware boot (`rm_init_adapter`) needs the card's BARs and
  firmware load path; there is no pass-through equivalent.

So use this guest to get macOS running, map the OpenCore settings the driver
wants (`csr-active-config`, `boot-args`, `SecureBootModel Disabled`), and stage
the driver package. Actually exercising Metal requires PCI passthrough.

## Adding passthrough later

The hardware is already prepared: `0000:01:00.0` (RTX 5080 Max-Q) and
`0000:01:00.1` (HDMI audio) are bound to `vfio-pci`, and `intel_iommu=on
iommu=pt` is set in `modules/hardware/virtualization.nix`.

To pass the GPU through, add to `macos.xml` (mirroring the win11 dGPU VMs)
and **remove the `<video>` element**, since the passed-through card becomes the
display:

```xml
<hostdev mode='subsystem' type='pci' managed='no'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
  <rom bar='off'/>
</hostdev>
<hostdev mode='subsystem' type='pci' managed='no'>
  <driver name='vfio'/>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
  </source>
  <rom bar='off'/>
</hostdev>
```

Two things to verify before expecting the driver to work on the card:

1. **Laptop MUX.** On this ASUS the dGPU is wired to the internal panel through
   a MUX. Confirm the panel and the dGPU share a path, or use an external
   output, before chasing driver bugs.
2. **RTX 5080 Max-Q is `10de:2c59` (GB203M).** The NullMoth package was tested
   only on an RTX 5060 (`2d05`); its NVRM maps the GB20X family to
   `gsp_ga10x.bin`, but mobile Blackwell is not a tested target.

None of the NullMoth driver's own OpenCore requirements are set in this VM yet —
they come from *its* install, not from OSX-KVM: `ResizeGpuBars=13`,
`ResizeAppleGpuBars=-1`, `Kernel -> Block com.apple.iokit.IONDRVSupport`, and
`SecureBootModel Disabled`.
