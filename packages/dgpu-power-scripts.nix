{
  writeScriptBin,
  psmisc,
  pciutils,
}: {
  # Power off the NVIDIA dGPU completely (invisible to the system).
  # Mirrors supergfxctl's Integrated-mode sequence:
  #   stop services -> kill users -> unload modules -> unbind+remove from
  #   PCI tree -> firmware/slot power-off.
  "dgpu-off" = writeScriptBin "dgpu-off" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }
    fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }
    warn()   { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }

    usage() {
        echo "Usage: dgpu-off [-s] [-f] [-m asus|slot|remove]"
        echo ""
        echo "  Turn the NVIDIA dGPU completely off / invisible."
        echo ""
        echo "  -s          silent/scripted: no prompts, exit 1 on blockers"
        echo "  -f          force: kill processes holding the GPU"
        echo "  -m METHOD   power-off method (default: auto)"
        echo "                asus    ASUS WMI dgpu_disable (firmware level,"
        echo "                        survives pci rescan AND reboot)"
        echo "                slot    PCIe slot power (kernel level, reset on boot)"
        echo "                remove  PCI tree remove only (until rescan/reboot)"
    }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    SILENT=false
    FORCE=false
    METHOD=auto
    while [ $# -gt 0 ]; do
        case "$1" in
            -s) SILENT=true ;;
            -f) FORCE=true ;;
            -m) shift; METHOD="''${1:-auto}" ;;
            -h|--help) usage; exit 0 ;;
            *) red "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done

    ASUS_DGPU_DISABLE=/sys/devices/platform/asus-nb-wmi/dgpu_disable
    ASUS_GPU_MUX=/sys/devices/platform/asus-nb-wmi/gpu_mux_mode
    STATE_DIR=/var/lib/dgpu-power
    STATE_FILE=$STATE_DIR/state

    asus_dgpu_write() {
        # Firmware WMI call can transiently fail -> retry like supergfxctl
        local val=$1 tries=0 cur
        while :; do
            if echo "$val" > "$ASUS_DGPU_DISABLE" 2>/dev/null; then
                sleep 0.1
                cur=$(tr -dc '01' < "$ASUS_DGPU_DISABLE" 2>/dev/null || true)
                [ "$cur" = "$val" ] && return 0
            fi
            tries=$((tries + 1))
            [ "$tries" -ge 4 ] && return 1
            sleep 0.5
        done
    }

    # ── Resolve method ───────────────────────────────────────────
    if [ "$METHOD" = "auto" ]; then
        if [ -f "$ASUS_DGPU_DISABLE" ]; then
            METHOD=asus
        elif ls /sys/bus/pci/slots/*/power >/dev/null 2>&1; then
            METHOD=slot
        else
            METHOD=remove
        fi
    fi
    case "$METHOD" in asus|slot|remove) ;; *) red "Invalid method: $METHOD"; exit 1 ;; esac
    if [ "$METHOD" = "asus" ] && [ ! -f "$ASUS_DGPU_DISABLE" ]; then
        red "ERROR: $ASUS_DGPU_DISABLE not available (asus-nb-wmi not loaded?)"
        exit 1
    fi
    info "Power-off method: $METHOD"

    # ── SAFETY: never disable the dGPU while the MUX drives the display ──
    # (same hard rule as supergfxctl's asus_boot_safety_check — doing this
    #  while gpu_mux_mode=0 would leave you with no display output)
    if [ -f "$ASUS_GPU_MUX" ]; then
        mux=$(tr -dc '01' < "$ASUS_GPU_MUX" 2>/dev/null || true)
        if [ "$mux" = "0" ]; then
            red "ERROR: GPU MUX is in dGPU/Discrete mode (gpu_mux_mode=0)."
            red "The dGPU is driving your display — disabling it would kill all output."
            red "Switch the MUX to Optimus/Hybrid first, reboot, then retry."
            exit 1
        fi
    fi

    # ── Discover NVIDIA dGPU functions ───────────────────────────
    GPU_BDF=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$GPU_BDF" ]; then
        if [ -f "$ASUS_DGPU_DISABLE" ] && grep -q 1 "$ASUS_DGPU_DISABLE" 2>/dev/null; then
            mkdir -p "$STATE_DIR"
            echo "off-asus" > "$STATE_FILE"
            green "dGPU is already disabled via ASUS dgpu_disable. Nothing to do."
            exit 0
        fi
        red "ERROR: No NVIDIA GPU (class 03xx) found on PCI bus."
        exit 1
    fi
    GPU_BUSDEV="''${GPU_BDF%.*}"

    ALL_DEVS=()
    ALL_DRIVERS=()
    IOMMU_GROUPS=()
    while IFS= read -r line; do
        bdf=$(echo "$line" | awk '{print $1}')
        drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        iommu=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")
        ALL_DEVS+=("$bdf")
        ALL_DRIVERS+=("$drv")
        IOMMU_GROUPS+=("$iommu")
    done < <(${pciutils}/bin/lspci -D -s "$GPU_BUSDEV".* -d 10DE: 2>/dev/null)

    echo "" >&2
    info "Found ''${#ALL_DEVS[@]} NVIDIA device function(s):"
    for i in "''${!ALL_DEVS[@]}"; do
        desc=$(${pciutils}/bin/lspci -s "''${ALL_DEVS[$i]}" 2>/dev/null | cut -d' ' -f2-)
        printf "  %-13s  driver: %-10s  %s\n" \
            "''${ALL_DEVS[$i]}" "''${ALL_DRIVERS[$i]}" "$desc" >&2
    done

    # ── Blocker: running VM holding the IOMMU group ──────────────
    for iommu in $(printf '%s\n' "''${IOMMU_GROUPS[@]}" | sort -u); do
        [ "$iommu" = "?" ] && continue
        if [ -e "/dev/vfio/$iommu" ] && ${psmisc}/bin/fuser "/dev/vfio/$iommu" >/dev/null 2>&1; then
            red "ERROR: IOMMU group $iommu is in use by a running VM!"
            ${psmisc}/bin/fuser -v "/dev/vfio/$iommu" 2>&1 | sed 's/^/  /' >&2
            red "Shut down the VM first."
            exit 1
        fi
    done

    # ── Blocker: displays actively driven by the dGPU ────────────
    HAS_DISPLAY=false
    if [ -d "/sys/bus/pci/devices/$GPU_BDF/drm" ]; then
        for conn_dir in /sys/bus/pci/devices/"$GPU_BDF"/drm/card*/card*-*; do
            [ -d "$conn_dir" ] || continue
            status=$(cat "$conn_dir/status" 2>/dev/null || echo unknown)
            enabled=$(cat "$conn_dir/enabled" 2>/dev/null || echo disabled)
            if [ "$status" = "connected" ] && [ "$enabled" = "enabled" ]; then
                yellow "Display $(basename "$conn_dir") is ACTIVE on the dGPU"
                HAS_DISPLAY=true
            fi
        done
    fi

    # ── Blocker: processes using nvidia devices ──────────────────
    IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"
    has_procs=false
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids=$(${psmisc}/bin/fuser "$nvdev" 2>/dev/null || true)
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            echo "$pname" | grep -qE "$IGNORE_PROCS" && continue
            if ! $has_procs; then echo "" >&2; yellow "Processes using NVIDIA devices:"; fi
            has_procs=true
            echo "  PID $pid  ($pname)  [$nvdev]" >&2
        done
    done

    if $has_procs || $HAS_DISPLAY; then
        if $FORCE; then
            warn "Force mode: killing processes holding NVIDIA devices..."
            for nvdev in /dev/nvidia*; do
                [ -e "$nvdev" ] || continue
                ${psmisc}/bin/fuser -k "$nvdev" 2>/dev/null || true
            done
            sleep 1
        elif $SILENT; then
            yellow "dGPU is busy (processes or active display). Aborting (-s)."
            exit 1
        else
            echo "" >&2
            yellow "The dGPU is currently in use. Turning it off will kill these users."
            read -rp "Kill them and continue? [y/N] " ans
            if [[ "$ans" =~ ^[Yy] ]]; then
                for nvdev in /dev/nvidia*; do
                    [ -e "$nvdev" ] || continue
                    ${psmisc}/bin/fuser -k "$nvdev" 2>/dev/null || true
                done
                sleep 1
            else
                red "Aborted."
                exit 1
            fi
        fi
    fi

    # ── Stop NVIDIA services ─────────────────────────────────────
    info "Stopping NVIDIA services..."
    systemctl stop nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced stopped" || true
    systemctl stop nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd stopped" || true

    # ── Unload NVIDIA kernel modules (retry like supergfxctl) ────
    info "Unloading NVIDIA kernel modules..."
    for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia nvidia_wmi_ec_backlight; do
        lsmod | grep -q "^$mod " || continue
        tries=0
        while ! rmmod "$mod" 2>/dev/null; do
            tries=$((tries + 1))
            if [ "$tries" -ge 6 ]; then
                warn "Could not remove module: $mod (continuing anyway)"
                break
            fi
            sleep 0.2
        done
        lsmod | grep -q "^$mod " || ok "Removed module: $mod"
    done

    # ── Unbind + remove all functions from PCI tree (reverse order) ──
    info "Removing NVIDIA functions from the PCI tree..."
    for ((i=''${#ALL_DEVS[@]}-1; i>=0; i--)); do
        dev="''${ALL_DEVS[$i]}"
        if [ -e "/sys/bus/pci/devices/$dev/driver/unbind" ]; then
            echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null || true
        fi
        if [ -e "/sys/bus/pci/devices/$dev/remove" ]; then
            echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>/dev/null || true
            ok "Removed $dev from PCI tree"
        fi
    done
    sleep 0.5

    # ── Cut the power ────────────────────────────────────────────
    case "$METHOD" in
        asus)
            info "Setting ASUS dgpu_disable=1 (firmware-level off)..."
            if asus_dgpu_write 1; then
                ok "dgpu_disable = 1"
            else
                fail "Could not set dgpu_disable. Check dmesg."
                exit 1
            fi
            ;;
        slot)
            SLOT_FOUND=false
            for slot in /sys/bus/pci/slots/*/; do
                addr=$(cat "$slot/address" 2>/dev/null || true)
                if [ -n "$addr" ] && [ "$addr" = "$GPU_BUSDEV" ]; then
                    info "Powering off PCIe slot $(basename "$slot") ($addr)..."
                    echo 0 > "$slot/power" 2>/dev/null || true
                    SLOT_FOUND=true
                fi
            done
            if ! $SLOT_FOUND; then
                warn "No hotplug slot matches $GPU_BUSDEV — falling back to remove-only."
                METHOD=remove
            fi
            ;;
        remove)
            info "Devices removed from PCI tree (visible again after rescan/reboot)."
            ;;
    esac

    mkdir -p "$STATE_DIR"
    echo "off-$METHOD $GPU_BUSDEV" > "$STATE_FILE"

    # ── Verify ───────────────────────────────────────────────────
    sleep 0.5
    if [ -z "$(${pciutils}/bin/lspci -d 10DE: 2>/dev/null)" ]; then
        echo "" >&2
        green "dGPU is now OFF and invisible to the system."
        case "$METHOD" in
            asus)   yellow "Firmware-level: persists across reboots (and rescan). Run dgpu-on to restore." ;;
            slot)   yellow "Slot-level: comes back on reboot. Run dgpu-on to restore." ;;
            remove) yellow "Tree-level only: comes back on pci rescan or reboot. Run dgpu-on to restore." ;;
        esac
    else
        fail "NVIDIA devices still visible on the PCI bus. Check dmesg."
        exit 1
    fi
  '';

  # Power the NVIDIA dGPU back on and return it to the host nvidia driver.
  "dgpu-on" = writeScriptBin "dgpu-on" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }
    fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }
    warn()   { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    SILENT=false
    case "''${1:-}" in -s) SILENT=true; shift;; esac

    ASUS_DGPU_DISABLE=/sys/devices/platform/asus-nb-wmi/dgpu_disable
    STATE_DIR=/var/lib/dgpu-power
    STATE_FILE=$STATE_DIR/state

    asus_dgpu_write() {
        local val=$1 tries=0 cur
        while :; do
            if echo "$val" > "$ASUS_DGPU_DISABLE" 2>/dev/null; then
                sleep 0.1
                cur=$(tr -dc '01' < "$ASUS_DGPU_DISABLE" 2>/dev/null || true)
                [ "$cur" = "$val" ] && return 0
            fi
            tries=$((tries + 1))
            [ "$tries" -ge 4 ] && return 1
            sleep 0.5
        done
    }

    STATE_MODE=""
    STATE_ADDR=""
    if [ -r "$STATE_FILE" ]; then
        read -r STATE_MODE STATE_ADDR < "$STATE_FILE" || true
    fi

    # ── Re-enable firmware / slot power ──────────────────────────
    if [ -f "$ASUS_DGPU_DISABLE" ] && grep -q 1 "$ASUS_DGPU_DISABLE" 2>/dev/null; then
        info "Setting ASUS dgpu_disable=0..."
        if asus_dgpu_write 0; then
            ok "dgpu_disable = 0"
        else
            fail "Could not clear dgpu_disable. Check dmesg."
            exit 1
        fi
        sleep 0.2
    fi

    for slot in /sys/bus/pci/slots/*/; do
        [ -e "$slot/power" ] || continue
        addr=$(cat "$slot/address" 2>/dev/null || true)
        power=$(tr -dc '01' < "$slot/power" 2>/dev/null || true)
        if [ "$power" = "0" ]; then
            if [ -n "$STATE_ADDR" ] && [ "$addr" != "$STATE_ADDR" ]; then continue; fi
            info "Powering on PCIe slot $(basename "$slot") ($addr)..."
            echo 1 > "$slot/power" 2>/dev/null || true
        fi
    done

    # ── Rescan and wait for the GPU to appear ────────────────────
    info "Rescanning PCI bus..."
    GPU_BDF=""
    for _ in $(seq 1 16); do
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 0.5
        GPU_BDF=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
        [ -n "$GPU_BDF" ] && break
    done

    if [ -z "$GPU_BDF" ]; then
        fail "NVIDIA GPU did not reappear on the PCI bus."
        yellow "Try: cat $ASUS_DGPU_DISABLE ; echo 1 > /sys/bus/pci/rescan ; or reboot."
        exit 1
    fi
    GPU_BUSDEV="''${GPU_BDF%.*}"
    ok "GPU is back at $GPU_BDF"

    ALL_DEVS=()
    while IFS= read -r line; do
        ALL_DEVS+=("$(echo "$line" | awk '{print $1}')")
    done < <(${pciutils}/bin/lspci -D -s "$GPU_BUSDEV".* -d 10DE: 2>/dev/null)

    # ── Make sure nothing steers the GPU to vfio-pci ─────────────
    # (a previous gpu-to-vfio may have left a dynamic new_id behind)
    for dev in "''${ALL_DEVS[@]}"; do
        pci_id=$(${pciutils}/bin/lspci -ns "$dev" 2>/dev/null | awk '{print $3}')
        if [ -n "$pci_id" ]; then
            echo "$pci_id" | sed 's/:/ /' > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
        fi
        echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [ "$cur_drv" = "vfio-pci" ]; then
            echo "$dev" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        fi
    done

    # ── Load nvidia and bind ─────────────────────────────────────
    info "Loading NVIDIA kernel modules..."
    for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
        modprobe "$mod" 2>/dev/null || warn "Could not load $mod"
    done
    sleep 0.5

    for dev in "''${ALL_DEVS[@]}"; do
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [ "$cur_drv" = "none" ]; then
            echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        fi
    done
    sleep 1

    # ── Runtime PM: let the GPU sleep when idle ──────────────────
    for dev in "''${ALL_DEVS[@]}"; do
        pm_control="/sys/bus/pci/devices/$dev/power/control"
        [ -w "$pm_control" ] && echo auto > "$pm_control" 2>/dev/null || true
    done

    # ── Start NVIDIA services ────────────────────────────────────
    info "Starting NVIDIA services..."
    systemctl start nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced started" || true
    systemctl start nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd started" || true

    mkdir -p "$STATE_DIR"
    echo "on" > "$STATE_FILE"

    # ── Verify ───────────────────────────────────────────────────
    echo "" >&2
    all_ok=true
    for dev in "''${ALL_DEVS[@]}"; do
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        class=$(cut -c3-4 "/sys/bus/pci/devices/$dev/class" 2>/dev/null || true)
        if [ "$class" = "03" ] && [ "$cur_drv" != "nvidia" ]; then
            fail "$dev  →  $cur_drv  (expected nvidia)"
            all_ok=false
        else
            ok "$dev  →  $cur_drv"
        fi
    done

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi -L >/dev/null 2>&1; then
            ok "nvidia-smi reports GPU visible"
        else
            warn "nvidia-smi could not detect the GPU yet (may need a few seconds)"
        fi
    fi

    echo "" >&2
    if $all_ok; then
        green "dGPU is back ON and bound to the nvidia driver."
    else
        red "dGPU is powered but some functions are not on the expected driver."
        red "Check dmesg, or run gpu-to-host / reboot."
        exit 1
    fi
  '';

  # Quick overview of the dGPU power state
  "dgpu-power-status" = writeScriptBin "dgpu-power-status" ''
    #!/usr/bin/env bash
    set -euo pipefail

    cyan() { echo -e "\e[36m$*\e[0m"; }

    ASUS_DGPU_DISABLE=/sys/devices/platform/asus-nb-wmi/dgpu_disable
    ASUS_GPU_MUX=/sys/devices/platform/asus-nb-wmi/gpu_mux_mode
    STATE_FILE=/var/lib/dgpu-power/state

    echo ""
    cyan "═══ dGPU Power Status ═══"
    echo ""

    if [ -f "$ASUS_DGPU_DISABLE" ]; then
        v=$(tr -dc '01' < "$ASUS_DGPU_DISABLE" 2>/dev/null || echo "?")
        [ "$v" = "1" ] && echo "  asus dgpu_disable:  1  (dGPU firmware-disabled)" \
                       || echo "  asus dgpu_disable:  $v"
    else
        echo "  asus dgpu_disable:  (not available)"
    fi

    if [ -f "$ASUS_GPU_MUX" ]; then
        v=$(tr -dc '01' < "$ASUS_GPU_MUX" 2>/dev/null || echo "?")
        [ "$v" = "1" ] && echo "  asus gpu_mux_mode:  1  (Optimus/Hybrid)" \
                       || echo "  asus gpu_mux_mode:  $v  (Discrete — do NOT use dgpu-off!)"
    fi

    for slot in /sys/bus/pci/slots/*/; do
        [ -e "$slot/power" ] || continue
        addr=$(cat "$slot/address" 2>/dev/null || echo "?")
        power=$(tr -dc '01' < "$slot/power" 2>/dev/null || echo "?")
        echo "  pci slot $(basename "$slot"):        addr=$addr power=$power"
    done

    [ -f "$STATE_FILE" ] && echo "  saved state:        $(cat "$STATE_FILE")"

    echo ""
    FOUND=false
    while IFS= read -r line; do
        FOUND=true
        bdf=$(echo "$line" | awk '{print $1}')
        drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        pm=$(cat "/sys/bus/pci/devices/$bdf/power/runtime_status" 2>/dev/null || echo "?")
        printf "  %-13s  driver: %-10s  pm: %-9s  %s\n" \
            "$bdf" "$drv" "$pm" "$(echo "$line" | cut -d' ' -f2-)"
    done < <(${pciutils}/bin/lspci -D -d 10DE: 2>/dev/null)

    if ! $FOUND; then
        echo "  No NVIDIA devices on the PCI bus — dGPU is OFF / invisible."
        echo ""
        echo "  To bring it back:  sudo dgpu-on"
    else
        echo ""
        echo "  To turn it off:    sudo dgpu-off"
    fi
    echo ""
  '';
}
