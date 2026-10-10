# 1401 "cannot find valid EFI partition" — cause and fix

**Symptom.** 1401 (Mac app, v1.1.1) stops with:

```
OpenCore's startup partition could not be confirmed
  - select the partition this Mac started from
```

or a "cannot find valid EFI partition" message, **regardless of which ESP the
machine booted from.**

---

## 1. Root cause: OpenCore never wrote `boot-path`

1401 v1.1.0's release notes contain the change that introduced this:

> *"Require startup-partition ownership evidence before internal EFI operations;
> remove the timestamp-only fallback."*

The evidence it requires is OpenCore's NVRAM variable
`4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path`. From
`1401.app/Contents/Resources/nullmoth-setup.sh`:

```bash
booted_part() { # the partition OpenCore started this Mac from, read from OpenCore's boot-path variable
  local bp u d
  bp=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path 2>/dev/null | cut -f2-)
  u=$(printf '%s' "$bp" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [ -n "$u" ] || return 1
  for d in $(diskutil list | grep -oE 'disk[0-9]+s[0-9]+$' | sort -u); do
    diskutil info "$d" 2>/dev/null | grep -qi "Partition UUID: *$u" && { echo "$d"; return 0; }; done
  return 1; }
```

and the gate that uses it:

```bash
if d=$(booted_part); then mount_efi "$d" && [ -n "$(ocrel_in "$mp")" ] \
   && { found=$d; BOOT_BOUND=1; ok "OpenCore started this Mac from $d"; }; fi
...
if [ "$BOOT_BOUND" != 1 ]; then
  stop "OpenCore's startup partition could not be confirmed - select the partition this Mac started from"
fi
```

**The variable did not exist.** Measured on the machine:

```
$ nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version
4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version  REL-109-2026-09-30

$ nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path
nvram: Error getting variable - '...boot-path': (iokit/common) data was not found
```

OpenCore *had* started the Mac (the version variable proves it), but had never
written the boot path.

## 2. Why it was never written

OpenCore gates that variable behind one bit of `Misc -> Security ->
ExposeSensitiveData`. From `Docs/Configuration.tex`:

```
0x01 --- Expose the printable booter path as a UEFI variable.
0x02 --- Expose the OpenCore version as a UEFI variable.
0x04 --- Expose the OpenCore version in the OpenCore picker menu title.
0x08 --- Expose OEM information as a set of UEFI variables.
```

The config had the **OpenCore failsafe value**:

```
ExposeSensitiveData = 6      # 0x02 | 0x04   -> boot path NOT exposed
```

So bit `0x01` was missing and OpenCore had no reason to write `boot-path`. The
Delete list only covered `rtc-blacklist`, `revcpu`, `revcpuname` and `revpatch`,
so nothing was removing it either. `WriteFlash` was `True` and `OpenRuntime.efi`
was loaded — all correct. It was purely the exposure bit.

**This is why it failed from both the USB and the internal ESP:** the variable
was never written in either case. The problem was never which disk was booted.

## 3. The fix

```bash
# on both ESPs
Misc -> Security -> ExposeSensitiveData = 7    # 0x01 | 0x02 | 0x04
```

Applied to the USB and the internal ESP. OpenCore now writes `boot-path` on
every boot, naming whichever partition it actually started from — so 1401 works
from either, with no per-ESP configuration.

Verify after one reboot:

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path
```

It should contain the partition UUID of the ESP that booted. Cross-check against
`diskutil info diskXsY | grep "Partition UUID"`.

**Note:** a hand-set `boot-path` works too, but only for one ESP, because it is a
single NVRAM variable. It is now redundant — OpenCore overwrites it correctly.

## 3b. A SECOND, independent cause: unmounted ESPs

Fixing `boot-path` is not sufficient. The script also needs the ESP **mounted**,
and it tries to mount candidates itself:

```bash
mount_efi() {   # $1 = device or partition UUID; sets MOUNT_POINT in this shell
  local mp; mp=$(mnt "$1")
  if [ -z "$mp" ]; then diskutil mount "$1" >/dev/null 2>&1 || return 1; MOUNTED="$MOUNTED $1"; mp=$(mnt "$1"); fi
  MOUNT_POINT=$mp; [ -n "$MOUNT_POINT" ]; }
```

**A plain `diskutil mount` needs privilege, and the failure is discarded by
`>/dev/null 2>&1`.** So if the ESPs are not already mounted, every candidate is
silently skipped, `found` stays empty, and the user gets the *other* stop
message:

```
no OpenCore config for this Mac (MacBookPro16,2) on any connected disk -
plug in the disk or USB stick OpenCore started from, then try again
```

**Two different messages, two different causes.** `boot-path` missing gives
*"startup partition could not be confirmed"*; unmounted ESPs give *"no OpenCore
config ... on any connected disk"*. Both were present on this machine.

**Fix / workaround — mount the ESPs before launching 1401:**

```bash
sudo diskutil mount disk0s1     # resolve the device by UUID, not disk number
sudo diskutil mount disk1s1
```

Confirm the app will succeed before launching it:

```bash
bp=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | cut -f2-)
u=$(printf '%s' "$bp" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
d=$(for c in $(diskutil list | grep -oE 'disk[0-9]+s[0-9]+$'); do \
      diskutil info "$c" 2>/dev/null | grep -qi "Partition UUID: *$u" && echo "$c"; done)
diskutil info "$d" | awk -F': *' '/Mount Point/{print $2}'
```

**Diagnostic trap:** if you mount the ESPs yourself while investigating, 1401
appears to work and the fault looks intermittent. It is not — it depends purely
on whether the partitions happen to be mounted when the app runs.

## 4. Workaround if the variable is ever missing again

The setup script accepts an explicit partition, which bypasses `booted_part()`
entirely:

```bash
/Applications/1401.app/Contents/Resources/nullmoth-setup.sh --efi disk1s1
```

`--efi` is parsed at `nullmoth-setup.sh:13`. **The app does not surface this in
its UI**, so a user who hits the stop message has no in-app route past it.

## 5. Upstream compatibility issue

**OpenCore's failsafe for `ExposeSensitiveData` is `0x6`** — the value the
OpenCore documentation itself lists, and therefore what a stock, untouched
config carries. **`boot-path` is consequently absent on any default setup.**

1401 v1.1.0 made a hard requirement of a variable that most users will not have,
and the failure message points at the partition selection rather than at the
missing NVRAM exposure. That is a compatibility gap between 1401 1.1.0 and
default OpenCore configurations, not a machine-specific fault.

**Reasonable fixes on the 1401 side, in order of preference:**

1. When `boot-path` is absent, fall back to asking the user which partition to
   use — the `--efi` machinery already exists.
2. Detect the missing variable and say so explicitly, with the one-line remedy
   (`ExposeSensitiveData = 7`), instead of reporting a partition-selection
   problem.
3. Document the requirement in the release notes and the preflight output.

**Worth noting for the report:** the check itself is sound — refusing to migrate
OpenCore between disks is the right call, and the old timestamp fallback was
genuinely unsafe. The gap is only in how the missing evidence is surfaced.

## 6. Reference values on this machine

```
ESP partition UUIDs
  disk0s1  EFI SYSTEM   76458A36-C0A7-42FA-B52B-5FF2F0191461   (Windows ESP)
  disk1s1  EFI NO NAME  6A72E4BD-561E-4A78-9D04-B4A32B84CC86   (internal, macOS)

OpenCore NVRAM GUID   4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102
  opencore-version    REL-109-2026-09-30
  boot-path           (was absent; now written by OpenCore)
```

**Caveat:** disk enumeration is **not stable across reboots** on this machine —
`disk0`/`disk1` have swapped between boots. Always resolve ESPs by partition UUID
or volume name, never by disk number.
