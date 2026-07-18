# ASUS ROG GPU Power Management — asusd internals

Based on source code analysis of `asusctl`/`asusd` (rog-platform, asus-armoury kernel module).

## Architecture

```
rog-control-center  ──dbus──>  asusd  ──sysfs──>  kernel (asus-armoury)  ──WMI──>  EC firmware  ──hardware──>  GPU power delivery
                                  │
                                  ├── /sys/class/firmware-attributes/asus-armoury/attributes/<attr>/current_value
                                  ├── /sys/firmware/acpi/platform_profile
                                  └── systemctl start/stop nvidia-powerd.service
```

## Sysfs attributes (GPU power)

All under `/sys/class/firmware-attributes/asus-armoury/attributes/`:

| File | WMI DevID | Type | Meaning |
|------|-----------|------|---------|
| `nv_base_tgp/current_value` | `0x00120099` | read-only | Base TGP of the dGPU (e.g. 80W) |
| `nv_tgp/current_value` | `0x00120098` | write | Additional TGP **on top of** base (range 0–70) |
| `nv_dynamic_boost/current_value` | `0x00120095` | write | Dynamic Boost allocation on top (range 0–25) |
| `nv_temp_target/current_value` | `0x00120096` | write | GPU temperature target (range 75–87) |

Each attribute directory also contains `min_value`, `max_value`, `default_value`, `display_name`.

## Power calculation

From the kernel patch (`asus-armoury.c`):

```
max-tgp      = queried from nvidia-smi (e.g. 175W)
max-boost    = nv_dynamic_boost_max (e.g. 25W)
base-tgp     = nv_base_tgp (read-only, e.g. 80W)

max additional TGP = max-tgp - max-boost - base-tgp
                   = 175 - 25 - 80 = 70W

total GPU power = base-tgp + nv_tgp + nv_dynamic_boost
```

Where `nv_tgp` max is defined in the kernel as `NVIDIA_GPU_POWER_MAX 70`.
`nv_dynamic_boost` max is defined as `NVIDIA_BOOST_MAX 25`.

## Platform profile

The throttle thermal policy is set via:

```
/sys/firmware/acpi/platform_profile
```

Values: `quiet`, `balanced`, `performance`

Writing to this file triggers the kernel's platform-profile subsystem which calls ASUS WMI methods to set EC fan curves and thermal limits. This is independent of the sysfs TGP attributes.

## How asusd applies settings

### On profile change (AC → Performance):

1. Read the current config section (`ac_profile_tunings[Performance]` or `dc_profile_tunings[BatteryProfile]`)
2. Check if PPT tuning is `enabled`
3. Iterate all `FirmwareAttributeType::Ppt` attributes and write `current_value` from config
4. If no config value exists, write the sysfs `default_value` instead
5. Re-apply fan curves (setting fan curves puts EC in manual fan mode)
6. Restart `nvidia-powerd` via `systemctl try-restart nvidia-powerd.service`

### On AC plug/unplug:

1. Detect power source change via udev (`/sys/class/power_supply/*/type`)
2. Switch platform profile based on config (`platform_profile_on_ac` / `platform_profile_on_battery`)
3. Start/stop `nvidia-powerd` based on `disable_nvidia_powerd_on_battery`
4. Re-apply PPT tunings and fan curves for the new profile

### On boot/resume:

1. Restore charge limit
2. Switch to the correct platform profile for current power source
3. PPT tunings are applied by the profile change handler

## Config storage (`/etc/asusd/asusd.ron`)

Key sections:

```ron
(
    platform_profile_on_ac: Performance,
    platform_profile_on_battery: Quiet,
    disable_nvidia_powerd_on_battery: true,
    ac_profile_tunings: {
        Performance: (
            enabled: true,
            group: {
                nv_tgp: 70,
                nv_dynamic_boost: 25,
                nv_temp_target: 87,
                ppt_pl1_spl: 125,
                ppt_pl2_sppt: 125,
                // ... other PPT limits
            },
        ),
        Balanced: (
            enabled: false,
            group: {},
        ),
        Quiet: (
            enabled: false,
            group: {},
        ),
    },
    dc_profile_tunings: {
        // ... same structure for battery
    },
)
```

## Replicating with scripts

### Set max GPU power:

```bash
#!/bin/bash
# Requires: kernel with asus-armoury support
BASE=/sys/class/firmware-attributes/asus-armoury/attributes

echo 70 | sudo tee "$BASE/nv_tgp/current_value"
echo 25 | sudo tee "$BASE/nv_dynamic_boost/current_value"
echo 87 | sudo tee "$BASE/nv_temp_target/current_value"
```

### Set platform profile:

```bash
echo performance | sudo tee /sys/firmware/acpi/platform_profile
```

### Combine for VM launch:

```bash
#!/bin/bash
set -euo pipefail

# 1. Set GPU to max power
BASE=/sys/class/firmware-attributes/asus-armoury/attributes
echo 70 | sudo tee "$BASE/nv_tgp/current_value" 2>/dev/null || true
echo 25 | sudo tee "$BASE/nv_dynamic_boost/current_value" 2>/dev/null || true

# 2. Performance profile
echo performance | sudo tee /sys/firmware/acpi/platform_profile 2>/dev/null || true

# 3. Start nvidia-powerd (fails silently if GPU on vfio-pci)
sudo systemctl try-start nvidia-powerd.service 2>/dev/null || true

# 4. Launch VM
virsh -c qemu:///system start "$1"
```

### Restore defaults:

```bash
#!/bin/bash
BASE=/sys/class/firmware-attributes/asus-armoury/attributes
for attr in nv_tgp nv_dynamic_boost nv_temp_target; do
    default=$(cat "$BASE/$attr/default_value" 2>/dev/null || echo 0)
    echo "$default" | sudo tee "$BASE/$attr/current_value" 2>/dev/null || true
done
echo balanced | sudo tee /sys/firmware/acpi/platform_profile 2>/dev/null || true
```

## Limitation for GPU passthrough

Writing `nv_tgp` configures the **EC** to allow higher power delivery at the hardware level. However, the NVIDIA driver inside the Windows VM reads its power limit from the **GPU's vBIOS registers**, not from the EC. Since the EC negotiation channel is severed in passthrough, the vBIOS base TGP (80W) is what the driver sees. The EC-level limits set via these sysfs files do **not** affect the GPU's internal power limit registers.

This is why `nvidia-smi -pl` on older drivers works — it writes directly to the GPU's power management registers, bypassing the EC entirely.
