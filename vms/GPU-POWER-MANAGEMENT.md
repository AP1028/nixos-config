# ASUS ROG GPU Power Management — asusd internals

Based on source code analysis of `asusctl`/`asusd` v6.x (rog-platform, rog-profiles, asus-armoury kernel module).

## Architecture

```
rog-control-center          asusctl CLI
       │                       │
       └──────dbus (xyz.ljones.*)────── asusd (system daemon)
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    │                          │                          │
         /sys/class/firmware-attributes  /sys/firmware/acpi      systemctl start/stop
         /asus-armoury/attributes/     platform_profile         nvidia-powerd.service
                    │                          │
             kernel asus-armoury          kernel acpi-platform-profile
             WMI → EC firmware             WMI → EC firmware
                    │                          │
             GPU power delivery          Fan curves, thermal policy
```

## Filesystem interface

### 1. ASUS Armoury sysfs (`/sys/class/firmware-attributes/asus-armoury/attributes/`)

All platform tuning attributes live here. Each is a directory containing:
- `current_value` — read/write (or read-only)
- `default_value`, `min_value`, `max_value`, `scalar_increment`
- `display_name`, `possible_values`

#### GPU Power Attributes

| Attribute dir | WMI DevID | Type | Meaning | Range |
|---|---|---|---|---|
| `nv_base_tgp` | `0x00120099` | read-only | Base TGP of the dGPU (e.g. 80W) | — |
| `nv_tgp` | `0x00120098` | write | Additional TGP on top of base | 0–70 |
| `nv_dynamic_boost` | `0x00120095` | write | Dynamic Boost allocation | 0–25 |
| `nv_temp_target` | `0x00120096` | write | GPU temperature target | 75–87 |

#### CPU Power Attributes (PPT)

| Attribute dir | WMI DevID | Meaning |
|---|---|---|
| `ppt_pl1_spl` | `0x001200A1` | CPU Slow Package Limit (PL1) |
| `ppt_pl2_sppt` | `0x001200A2` | CPU Fast Package Limit (PL2, short burst) |
| `ppt_pl3_fppt` | `0x001200A3` | CPU Fast Package Limit (PL3, peak) |
| `ppt_apu_sppt` | `0x001200A4` | APU/SoC Slow Package Limit |
| `ppt_platform_sppt` | `0x001200A5` | Platform Slow Package Limit |
| `ppt_fppt` | `0x001200A6` | Fast Package Power Target |
| `ppt_pl1_spl_min` | — | CPU PL1 minimum clamp |
| `ppt_pl2_sppt_min` | — | CPU PL2 minimum clamp |
| `ppt_pl3_fppt_min` | — | CPU PL3 minimum clamp |

#### GPU Mode Attributes

| Attribute dir | Meaning | Values |
|---|---|---|
| `gpu_mux_mode` | BIOS MUX switch (discrete vs hybrid) | 0 = dGPU, 1 = Optimus |
| `dgpu_disable` | Disable dGPU | 0 = enabled, 1 = disabled |
| `egpu_enable` | Enable external GPU (XG Mobile) | 0 = off, 1 = on |
| `egpu_connected` | eGPU connection status | read-only |

#### Other Attributes

| Attribute dir | Meaning |
|---|---|
| `charge_mode` | Charging mode (0=normal, 1=slow, 2=bypass) |
| `boot_sound` | POST sound on/off |
| `panel_od` | Panel overdrive (response time) on/off |
| `mini_led_mode` | Mini-LED zone control |
| `mcu_powersave` | MCU powersave mode |
| `kbd_leds_awake` | Keyboard LED state when awake |
| `kbd_leds_sleep` | Keyboard LED state when asleep |
| `kbd_leds_boot` | Keyboard LED state during boot |
| `kbd_leds_shutdown` | Keyboard LED state during shutdown |

### 2. Platform profile (`/sys/firmware/acpi/`)

| File | Values |
|---|---|
| `platform_profile` | `quiet`, `balanced`, `performance`, `low-power`, `custom` |
| `platform_profile_choices` | Space-separated list of available profiles |

### 3. CPU frequency control (`/sys/devices/system/cpu/cpu*/cpufreq/`)

| File | Meaning |
|---|---|
| `scaling_governor` | CPU frequency governor (`powersave` or `performance`) |
| `energy_performance_preference` | EPP value (see below) |
| `energy_performance_available_preferences` | Available EPP values |

#### EPP values

| Enum | sysfs string | Used for |
|---|---|---|
| `CPUEPP::Default` | `default` | — |
| `CPUEPP::Performance` | `performance` | Performance profile |
| `CPUEPP::BalancePerformance` | `balance_performance` | Balanced profile |
| `CPUEPP::BalancePower` | `balance_power` | Custom profile |
| `CPUEPP::Power` | `power` | Quiet / LowPower |

#### Governor values

| Enum | sysfs string |
|---|---|
| `CPUGovernor::Performance` | `performance` |
| `CPUGovernor::Powersave` | `powersave` |

### 4. Platform device (`asus-nb-wmi`)

Found via udev at subsystem `platform` with sysname `asus-nb-wmi`. Path typically
`/sys/devices/platform/asus-nb-wmi/`. Also has various ATTR files for:
- `dgpu_disable`, `egpu_enable`, `panel_od`, `gpu_mux_mode`

### 5. Fan curves (hwmon)

Found via udev at subsystem `hwmon` with attribute `name = "asus_custom_fan_curve"`.
Each fan has files:

```
pwm{1,2,3}_enable              — 0=off, 1=manual, 2=auto-ec, 3=auto-custom-curve
pwm{1,2,3}_auto_point{1-8}_pwm — PWM duty cycle per point (0-255)
pwm{1,2,3}_auto_point{1-8}_temp — Temperature threshold per point (0-255 °C)
```

Fan mapping: `1` = CPU, `2` = GPU, `3` = MID (if present). 8 temperature/PWM
points define the curve.

### 6. Power supply (udev)

Found via udev at subsystem `power_supply`.

| attr | Value |
|---|---|
| `type` | `Mains`, `Battery`, `USB` |
| `online` (mains) | 1 = plugged, 0 = unplugged |
| `charge_control_end_threshold` (battery) | Charge limit percentage (20-100) |

Battery is selected by priority: has `charge_control_end_threshold` attr → sysname
starts with `BAT` → type is `Battery`.

## Profile switch — what actually happens

When `platform_profile` is set (e.g. `echo performance > /sys/firmware/acpi/platform_profile`):

1. The kernel's platform-profile subsystem receives the write
2. It calls the ASUS WMI driver's handler (`asus-wmi.c`)
3. The handler sends a WMI command to the EC to set the **throttle thermal policy**
4. The EC changes: fan curves, thermal limits, turbo behavior
5. User-space (asusd) then reacts to the change via inotify on `platform_profile`
6. On detecting the change, asusd applies PPT values and fan curves on top

**Critical**: `platform_profile` is a *kernel-to-EC* command. Writing it works even
if asusd is not running. The EC remembers the thermal policy in hardware.

## The complete startup/reload flow

When asusd starts or reloads (`Reloadable::reload`):

```
1. Restore charge_control_end_threshold from config
2. Read power online state (AC or battery)
3. Call update_policy_ac_or_bat()
   a. Select the configured profile for current power source
   b. Write platform_profile to sysfs
   c. Set CPU EPP if platform_profile_linked_epp is true
4. Run AC or battery command (script from config)
5. manage_nvidia_powerd() — start/stop nvidia-powerd
6. apply_fan_curves_and_ppt() — write fan curves, then write PPT values
```

## AC power change events

When AC is plugged/unplugged (detected via polling every 2 seconds or via
inotify on power_supply):

```
1. If change_platform_profile_on_ac/bat is enabled:
   a. Select profile for new power state
   b. Write platform_profile, set EPP
2. Run AC or battery command script
3. manage_nvidia_powerd()
   a. If disable_nvidia_powerd_on_battery=true:
      - AC plugged → systemctl start nvidia-powerd.service
      - AC unplugged → systemctl stop nvidia-powerd.service
   b. If disable_nvidia_powerd_on_battery=false:
      - Always try to start nvidia-powerd on AC
4. apply_fan_curves_and_ppt() for the active profile
5. If going to battery, restore charge limit
```

## Suspend/resume handling

On resume from sleep:
```
1. Restore charge_control_end_threshold
2. Check power source (may have changed while asleep)
3. If power source changed from last known state:
   → Same as AC power change event
4. apply_fan_curves_and_ppt()
```

## The PPT writing logic

From `set_config_or_default()` in `asusd/src/asus_armoury.rs`:

```
For each attribute in /sys/class/firmware-attributes/asus-armoury/attributes/:
    Determine its type via FirmwareAttributeType

    If type == Ppt:
        Get the tuning group for (current_power_source, current_profile)
        If the tuning group is enabled:
            If the attribute has a configured value in tuning.group:
                Write it to current_value
            Else:
                Write the sysfs default_value to current_value
                Save the default in tuning.group (persisted to config)

    If type == Immediate:
        If the attribute has a stored value in armoury_settings:
            Restore it

    If type == Gpu:
        Clean up stale persisted values (GPU writes are now
        in-memory only, applied at shutdown)

    If type == ReadOnly or Norestore:
        Ignore (clean up any stale persisted values)
```

## PPT tuning config structure

From `Config` in `asusd/src/config.rs`:

```
Config {
    platform_profile_on_ac: PlatformProfile,      // default: Performance
    platform_profile_on_battery: PlatformProfile,  // default: Quiet
    change_platform_profile_on_ac: bool,           // default: true
    change_platform_profile_on_battery: bool,      // default: true
    disable_nvidia_powerd_on_battery: bool,        // default: true
    platform_profile_linked_epp: bool,             // default: true

    profile_quiet_epp: CPUEPP,
    profile_balanced_epp: CPUEPP,
    profile_performance_epp: CPUEPP,
    profile_custom_epp: CPUEPP,

    ac_profile_tunings: HashMap<PlatformProfile, Tuning>,
    dc_profile_tunings: HashMap<PlatformProfile, Tuning>,

    armoury_settings: HashMap<FirmwareAttribute, i32>,  // non-PPT immediate attrs

    charge_control_end_threshold: u8,
    ac_command: String,     // script to run on AC plug
    bat_command: String,    // script to run on battery
}

Tuning {
    enabled: bool,
    group: HashMap<FirmwareAttribute, i32>,
}
```

Default `Tuning` is `{ enabled: false, group: {} }` for all profiles.
Only the profiles the user has configured via rog-control-center get populated.

## Complete script recreation of asusd

### 1. Charge limit

```bash
read_charge_limit()  { cat /sys/class/power_supply/BAT*/charge_control_end_threshold; }
set_charge_limit()   { echo "$1" | sudo tee /sys/class/power_supply/BAT*/charge_control_end_threshold; }
full_charge_oneshot(){ local l=$(read_charge_limit); set_charge_limit 100; sleep 2; set_charge_limit "$l"; }
```

### 2. Platform profile

```bash
get_profile()    { cat /sys/firmware/acpi/platform_profile; }
set_profile()    { echo "$1" | sudo tee /sys/firmware/acpi/platform_profile; }
available_profiles() { cat /sys/firmware/acpi/platform_profile_choices; }
```

### 3. CPU EPP

```bash
set_epp()        { echo "$1" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; }
set_governor()   { echo "$1" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; }
```

Profile → EPP mapping:
- `quiet`/`low-power` → `power`
- `balanced` → `balance_performance`
- `performance` → `performance`
- `custom` → `balance_power`

### 4. GPU power (ASUS armoury sysfs)

```bash
ARMOURY=/sys/class/firmware-attributes/asus-armoury/attributes

gpu_set_tgp()       { echo "$1" | sudo tee "$ARMOURY/nv_tgp/current_value"; }
gpu_set_dynboost()  { echo "$1" | sudo tee "$ARMOURY/nv_dynamic_boost/current_value"; }
gpu_set_temptarget(){ echo "$1" | sudo tee "$ARMOURY/nv_temp_target/current_value"; }
gpu_get_base_tgp()  { cat "$ARMOURY/nv_base_tgp/current_value"; }

# Set GPU to max allowed
gpu_max_power() {
    local base=$(gpu_get_base_tgp)
    gpu_set_tgp "$(cat "$ARMOURY/nv_tgp/max_value")"
    gpu_set_dynboost "$(cat "$ARMOURY/nv_dynamic_boost/max_value")"
    gpu_set_temptarget "$(cat "$ARMOURY/nv_temp_target/max_value")"
}

gpu_default_power() {
    for attr in nv_tgp nv_dynamic_boost nv_temp_target; do
        echo "$(cat "$ARMOURY/$attr/default_value")" | sudo tee "$ARMOURY/$attr/current_value"
    done
}
```

### 5. CPU power limits (PPT)

```bash
ppt_set() { echo "$2" | sudo tee "$ARMOURY/$1/current_value"; }
ppt_get() { cat "$ARMOURY/$1/current_value"; }

# Typical values for Performance profile on AC
ppt_set_perf() {
    ppt_set ppt_pl1_spl 125
    ppt_set ppt_pl2_sppt 125
    ppt_set ppt_pl3_fppt 125
    ppt_set ppt_apu_sppt 40
    ppt_set ppt_platform_sppt 50
}

# Reset to default
ppt_default() {
    for attr in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt ppt_apu_sppt ppt_platform_sppt ppt_fppt; do
        local d=$(cat "$ARMOURY/$attr/default_value" 2>/dev/null) && ppt_set "$attr" "$d"
    done
}
```

### 6. Fan curves

```bash
# Find the hwmon device
find_fan_device() {
    for d in /sys/class/hwmon/hwmon*/name; do
        if [ "$(cat "$d")" = "asus_custom_fan_curve" ]; then
            echo "$(dirname "$d")"
            return
        fi
    done
}

fan_enable_custom() {
    local dev=$(find_fan_device)
    # Enable custom curve on fan 1 (CPU), 2 (GPU), 3 (MID)
    for fan in 1 2 3; do
        [ -f "$dev/pwm${fan}_enable" ] && echo 4 | sudo tee "$dev/pwm${fan}_enable" 2>/dev/null || true
    done
}

fan_disable_custom() {
    local dev=$(find_fan_device)
    for fan in 1 2 3; do
        [ -f "$dev/pwm${fan}_enable" ] && echo 2 | sudo tee "$dev/pwm${fan}_enable" 2>/dev/null || true
    done
}

# Write a single fan curve point
fan_set_point() {
    local fan=$1 idx=$2 temp=$3 pwm=$4
    local dev=$(find_fan_device)
    echo "$temp" | sudo tee "$dev/pwm${fan}_auto_point${idx}_temp" 2>/dev/null
    echo "$pwm"  | sudo tee "$dev/pwm${fan}_auto_point${idx}_pwm" 2>/dev/null
}

# Read fan curve (returns 8 temp,pwm pairs)
fan_get_curve() {
    local fan=$1
    local dev=$(find_fan_device)
    for i in $(seq 1 8); do
        local t=$(cat "$dev/pwm${fan}_auto_point${i}_temp" 2>/dev/null || echo 0)
        local p=$(cat "$dev/pwm${fan}_auto_point${i}_pwm" 2>/dev/null || echo 0)
        echo "point$i: ${t}c ${p}($(( p * 100 / 255 ))%)"
    done
}
```

PWM values are 0-255 (raw) or percentage (converted internally). Writing 3 to
`pwm_enable` resets the fan to EC auto mode. Writing 4 enables custom curve.

### 7. GPU MUX mode

```bash
# Read and set MUX mode
# gpu_mux_mode: 0 = dGPU only (Ultimate), 1 = Optimus (hybrid)
gpu_mux_get() { cat "$ARMOURY/gpu_mux_mode/current_value"; }
gpu_mux_set() { echo "$1" | sudo tee "$ARMOURY/gpu_mux_mode/current_value"; }

# dgpu_disable: 0 = dGPU enabled, 1 = dGPU disabled
dgpu_disable_get() { cat "$ARMOURY/dgpu_disable/current_value"; }
dgpu_disable_set() { echo "$1" | sudo tee "$ARMOURY/dgpu_disable/current_value"; }
```

### 8. Power source detection

```bash
is_ac_plugged() {
    for d in /sys/class/power_supply/*; do
        [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] && [ "$(cat "$d/online" 2>/dev/null)" = "1" ] && return 0
    done
    return 1
}

# Poll for power changes (asusd polls every 2 seconds)
monitor_power() {
    local last=$(is_ac_plugged && echo 1 || echo 0)
    while true; do
        local now=$(is_ac_plugged && echo 1 || echo 0)
        [ "$now" != "$last" ] && echo "Power changed: AC=$now" && last=$now
        sleep 2
    done
}
```

## Complete profile switch script

This replicates what asusd does when switching to Performance mode:

```bash
#!/bin/bash
set -euo pipefail

profile="${1:-performance}"

# 1. Set platform profile (kernel → EC)
echo "$profile" | sudo tee /sys/firmware/acpi/platform_profile

# 2. Set CPU EPP
case "$profile" in
    performance) epp="performance" ;;
    balanced)    epp="balance_performance" ;;
    quiet|low-power) epp="power" ;;
    custom)      epp="balance_power" ;;
    *)           epp="balance_performance" ;;
esac
echo "$epp" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference 2>/dev/null || true

# 3. PPT values
ARMOURY=/sys/class/firmware-attributes/asus-armoury/attributes

if [ "$profile" = "performance" ]; then
    # GPU power
    echo 70 | sudo tee "$ARMOURY/nv_tgp/current_value" 2>/dev/null || true
    echo 25 | sudo tee "$ARMOURY/nv_dynamic_boost/current_value" 2>/dev/null || true
    echo 87 | sudo tee "$ARMOURY/nv_temp_target/current_value" 2>/dev/null || true

    # CPU PPT
    echo 125 | sudo tee "$ARMOURY/ppt_pl1_spl/current_value" 2>/dev/null || true
    echo 125 | sudo tee "$ARMOURY/ppt_pl2_sppt/current_value" 2>/dev/null || true
    echo 125 | sudo tee "$ARMOURY/ppt_pl3_fppt/current_value" 2>/dev/null || true
    echo 40  | sudo tee "$ARMOURY/ppt_apu_sppt/current_value" 2>/dev/null || true
    echo 50  | sudo tee "$ARMOURY/ppt_platform_sppt/current_value" 2>/dev/null || true
else
    # Defaults for non-performance profiles
    for attr in nv_tgp nv_dynamic_boost nv_temp_target \
                ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt ppt_apu_sppt ppt_platform_sppt ppt_fppt; do
        local d=$(cat "$ARMOURY/$attr/default_value" 2>/dev/null || echo 0)
        echo "$d" | sudo tee "$ARMOURY/$attr/current_value" 2>/dev/null || true
    done
fi

# 4. nvidia-powerd management
if [ "$profile" = "performance" ] || [ "$profile" = "balanced" ]; then
    sudo systemctl try-start nvidia-powerd.service 2>/dev/null || true
else
    sudo systemctl try-stop nvidia-powerd.service 2>/dev/null || true
fi
```

## Boot/startup script (replaces asusd Reloadable::reload)

```bash
#!/bin/bash
# Run at boot to restore state

# 1. Read power state
IS_AC=false
for d in /sys/class/power_supply/*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] && [ "$(cat "$d/online" 2>/dev/null)" = "1" ] && IS_AC=true
done

# 2. Select profile
if $IS_AC; then
    profile="performance"
else
    profile="quiet"
fi

# 3. Apply everything
echo "$profile" | sudo tee /sys/firmware/acpi/platform_profile

# 4. Run the profile script above
/path/to/set-profile.sh "$profile"
```

## Files referenced

| Path | Purpose |
|---|---|
| `/sys/class/firmware-attributes/asus-armoury/attributes/*/current_value` | Tuning values (GPU TGP, CPU PPT) |
| `/sys/firmware/acpi/platform_profile` | Throttle thermal policy |
| `/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference` | CPU EPP |
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | CPU governor |
| `/sys/class/power_supply/*/online` | AC power state |
| `/sys/class/power_supply/*/charge_control_end_threshold` | Battery charge limit |
| `/sys/class/hwmon/hwmon*/pwm*_auto_point*` | Fan curve data |
| `/etc/asusd/asusd.ron` | asusd config (RON format) |

## What asusd does that scripts can't easily replicate

| Feature | Reason |
|---|---|
| **DBus API** | asusd exposes `xyz.ljones.Platform` and `xyz.ljones.AsusArmoury` on dbus for rog-control-center |
| **inotify on config file** | Watches `asusd.ron` and re-applies settings on external edits |
| **Fan curve persistence** | Saves custom curves per profile to config and re-applies on boot/profile change |
| **Charge limit save/restore** | Saves base limit for one-shot full charge then restores |
| **External power event commands** | Runs user-defined `ac_command` / `bat_command` scripts |

## NPFC SSDT fix (unlocks 120W in VM)

The 80W cap in the VM was solved by injecting a custom SSDT that provides the
`\_SB_.NPCF` device (HW ID `NVDA0820`) — the NVIDIA Power Control Framework
that the Windows **NVIDIA Platform Controllers and Framework** driver talks to
for power budget authorization.

### Source

The SSDT is defined in `~/nixos-config/vms/ssdt-npcf.asl` and compiled to
`ssdt-npcf.aml`. Key values from the host's real SSDT18/`OptRf2`:

| Field | Value | Meaning |
|---|---|---|
| ACBT | 0xA0 (160) | AC GPU power budget |
| ATPP | 0x0118 (280) | AC total platform power |
| AMAT | 0xA0 (160) | Max GPU allocation |
| TPPL | 0x0001C138 | Total platform power limit |
| AMIT | 0xFFB0 | Min GPU allocation |

### What the SSDT does

The Windows NVIDIA driver queries `\_SB_.NPCF` via `_DSM` with UUID
`36b49710-2483-11e7-9598-0800200c9a66`. The critical sub-functions:

- **Func #0**: Returns capabilities bitmap (0x06BF)
- **Func #1**: Returns static config data
- **Func #2**: Returns power budget (TGPA=ACBT=160W → driver sets ~120W)
- **Func #3**: Returns temperature/fan curve info
- **Func #5**: Must return valid temperature data (or driver fails with code 31)

A simplified SSDT with only funcs #0-#3 caused code 31 because the driver
also needs func #5. A complete SSDT with all functions (including EC-dependent
#5, #7-#10) caused the VM to hang. The working version includes funcs #0-#3,
and a safe static version of #5 that doesn't reference the non-existent EC.

### Injection

Add both the battery SSDT and the NPFC SSDT to the VM's QEMU commandline:

```xml
<qemu:commandline>
    <qemu:arg value="-acpitable"/>
    <qemu:arg value="file=/var/lib/libvirt/vbios/ssdt-battery.aml"/>
    <qemu:arg value="-acpitable"/>
    <qemu:arg value="file=/var/lib/libvirt/vbios/ssdt-npcf.aml"/>
    ...
</qemu:commandline>
```

### Result

| Metric | Before | After |
|---|---|---|
| Current Power Limit | 80.00 W | 120.00 W |
| Platform Controller status | Unknown | OK |
| RQST Power Limit | 80.00 W | N/A |

`Requested Power Limit: N/A` is expected — that field is only populated by
`nvidia-powerd` which runs on the host and can't reach the GPU in a VM. The
GPU firmware applies the 120W cap directly from the NVML call.

### Remaining limitation

The NPFC ACPI injection raises the power limit from 80W to 120W, but the
`Requested Power Limit` stays `N/A` because `nvidia-powerd` (which runs on
the host) cannot reach the GPU when it's bound to `vfio-pci`. The GPU's
vBIOS base TGP (80W) and max TGP (130W) remain unchanged — the driver
applies the 120W limit as an override from the ACPI budget.

For the full 130W cap (matching the host's `Max Power Limit`), the ACBT
value in the SSDT could be tuned. Currently set to 0xA0 (160) which results
in 120W.
