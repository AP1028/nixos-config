# Current state and recovery (written before a host reboot)

## RESOLVED — the real cause, found by review

**I had deleted the entire `<qemu:commandline>` element from `vms/macos/macos.xml`.**
While cleaning up a failed `x-no-mmap` experiment I used the regex
`<qemu:commandline>.*?</qemu:commandline>`, which also removed the ORIGINAL block:
the CPU model (`-cpu Skylake-Client,...`), `isa-applesmc` (AppleSMC) and
`-smbios type=2`. Without those QEMU starts the guest with none of them and macOS
hangs at the Apple logo with zero CPU.

That single deletion **was** the hang. Everything else I suspected was wrong:
not the BAR size, not the OpenCore config, not the NVRAM, not the driver, not a
wedged GPU. The host reboot appeared to fix it only because the live libvirt domain
still carried the old definition at that moment.

Restoring the element verbatim from the last working commit (`a760c26`) fixed it
immediately: `autogo=up`, `IODisplay=1`, `budget=192MB`, Metal on the RTX 5080.

**Two traps that cost hours, worth remembering:**

1. `grep -c "<qemu:commandline>"` returned 2 because the string also appears in two
   **comments**. Counting mentions is not the same as finding the element — parse
   the XML, or match `^\s*<qemu:commandline>`.
2. A regex cleanup of "my" edit ate a neighbouring original block. Anchor such
   edits on the exact text added, and re-diff the whole file afterwards.

## Why this file exists (superseded by the section above)

A session of BAR-size experiments ended with the macOS guest hanging at the Apple
logo with **zero CPU** — a hard hang, not a slow boot. Everything guest-side was
ruled out, so a host reboot is the next step to reset the GPU/vfio state. This
records exactly what state the VM is in, so it can be resumed afterwards.

## Symptom

* QEMU's guest reaches the Apple logo (boot.efi runs) then **stops**: QEMU CPU time
  frozen (`00:00:12 -> 00:00:12` over 8 s), no progress bar, no SSH.
* Serial console stops at `#[EB|LOG:HANDOFF TO XNU] / End of efiboot serial output`
  (438 bytes) whenever the OpenCore config has no `debug=0x8 serial=1`.
* The **external display shows a stale TianoCore frame** — that is the GPU's last
  scanout from before the driver armed, and is *not* diagnostic. The truth is on
  the **QEMU virtual screen** (capture with `virsh screenshot`).

## What has been ruled out

| suspect | verdict |
|---|---|
| GPU hardware | ❌ **fine** — `win11-stealthy-dgpu` runs on the same card; host `lspci` shows BARs and 32GT/s x8, no AER errors |
| Host storage | ❌ fine — every image reads clean with `dd`; `qemu-img check` reports no errors on both qcow2 files |
| Guest data image | ❌ not it — hangs with the user's 63.7 GB image **and** the pre-driver backup |
| OpenCore config | ❌ not it — hangs with the pre-nullmoth backup restored byte-exact |
| NVRAM | ❌ not it — hangs with the backup restored **and** with the NVRAM deleted |
| Driver 1.0.6 | ❌ not it — hangs with the pre-driver image, which has no driver |
| Host BAR size | ❌ not it — hangs at 256 MB, 4 GiB, and 16 GiB |

**Remaining suspect: the physical GPU / vfio / KVM state**, after ~15 BAR resizes,
many vfio rebinds and one function-level reset. → **host reboot.**

## Exact current state of the VM

| item | value |
|---|---|
| `macos.img` | **pre-driver backup** (35,695,755,264 B) |
| `OpenCore.qcow2` | **pre-nullmoth backup** (36,175,872 B) |
| NVRAM (`/var/lib/libvirt/qemu/nvram/macos_VARS.fd`) | **deleted** (regenerates) |
| host BAR1 | 256 MB |
| domain `<video>` | **`vmvga`** — temporary, added so the boot can be seen. Restore `type='none'` once the driver is back. |
| domain `<serial>` | `type='file'` → `/tmp/macos-serial.log` (temporary, per the file's own note) |

## Backups (all intact)

```
/var/lib/libvirt/images/macos.img.before-restore                       63,716,458,496  <- the user's real data image
/var/lib/libvirt/images/macos.img.20261007-0535.pre-driver             35,695,755,264  <- pre-driver
/home/tianyixia/OSX-KVM/OpenCore/OpenCore.qcow2.myedits                    40,370,176  <- my edited config
/home/tianyixia/OSX-KVM/OpenCore/OpenCore.qcow2.20261007-0539.pre-nullmoth 36,175,872  <- pre-nullmoth
/tmp/macos_VARS.fd.backup                                                     540,672  <- NVRAM before my reset
```

## Recovery steps after the host reboot

1. Check the BAR came back at 256 MB (`gpu-to-vfio` service):
   `python3 -c "l=open('/sys/bus/pci/devices/0000:01:00.0/resource').readlines();a=int(l[1].split()[0],16);b=int(l[1].split()[1],16);print((b-a+1)/2**20,'MB')"`
2. Start the VM and watch the **virtual screen**:
   `virsh start macos; virsh screenshot macos /tmp/s.png --screen 0`
   (the screendump is a PNG regardless of the `.ppm`/`.png` suffix, and is
   root-owned — copy and chmod before reading.)
3. If it boots → confirm with SSH, then restore the user's data image:
   `cp --reflink=auto -p /var/lib/libvirt/images/macos.img.before-restore /var/lib/libvirt/images/macos.img`
4. Then re-install driver 1.0.6 (package is at `~/nullmoth-1.0.6/pkgroot` **on the
   guest** — if the image was reverted, re-copy from `/tmp/nm106/pkgroot` on the
   host) and re-apply the conf fix.
5. If it still hangs → the reboot did not fix it; the next suspect is the
   OpenCore ESP contents (its `fsck.fat` reported an I/O error at sector 0), and a
   fresh OpenCore image would be the way to test that.

## Tooling lessons (cost me a lot of time here)

* **`qemu-nbd --disconnect` while a filesystem is mounted leaves the mount stale**,
  and every later read/write fails with `Errno 5` while `qemu-img check` still
  reports the image as clean. That is how the OpenCore config got corrupted. Always
  `umount` first, verify with `sync`, and use `--fork`.
* The `fsck.fat "Read 512 bytes at 0: Input/output error"` and the `plistlib`
  `OSError: [Errno 5]` were **both** this stale-mount artifact, **not** disk
  corruption — `dd` read every image perfectly.
* Don't `pkill -f` patterns that match your own shell.
