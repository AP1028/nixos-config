{
  writeScriptBin,
  psmisc,
  pciutils,
}: {
  # Bind NVIDIA dGPU to vfio-pci for VM passthrough
    "gpu-to-vfio" = writeScriptBin "gpu-to-vfio" ''
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

    # ── Discover NVIDIA dGPU functions ───────────────────────────
    info "Discovering NVIDIA dGPU PCI functions..."

    GPU_BDF=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$GPU_BDF" ]; then
        red "ERROR: No NVIDIA GPU (class 03xx) found on PCI bus."
        exit 1
    fi
    GPU_BUSDEV="''${GPU_BDF%.*}"

    # Gather all NVIDIA functions on this device and their drivers
    ALL_DEVS=()
    ALL_DRIVERS=()
    while IFS= read -r line; do
        bdf=$(echo "$line" | awk '{print $1}')
        drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        ALL_DEVS+=("$bdf")
        ALL_DRIVERS+=("$drv")
    done < <(${pciutils}/bin/lspci -D -s "$GPU_BUSDEV".* -d 10DE: 2>/dev/null)

    if [ ''${#ALL_DEVS[@]} -eq 0 ]; then
        red "ERROR: No NVIDIA functions found on device $GPU_BUSDEV"
        exit 1
    fi

    # ── Show summary ─────────────────────────────────────────────
    if ! $SILENT; then
    echo ""
    info "Found ''${#ALL_DEVS[@]} NVIDIA device function(s):"
    for i in "''${!ALL_DEVS[@]}"; do
        desc=$(${pciutils}/bin/lspci -s "''${ALL_DEVS[$i]}" 2>/dev/null | cut -d' ' -f2-)
        iommu=$(basename "$(readlink "/sys/bus/pci/devices/''${ALL_DEVS[$i]}/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")
        printf "  %-13s  driver: %-10s  iommu_group: %-3s  %s\n" \
            "''${ALL_DEVS[$i]}" "''${ALL_DRIVERS[$i]}" "$iommu" "$desc"
    done
    fi

    # ── Check: already all on vfio-pci? ──────────────────────────
    all_vfio=true
    for drv in "''${ALL_DRIVERS[@]}"; do
        [ "$drv" != "vfio-pci" ] && all_vfio=false
    done
    if $all_vfio; then
        if $SILENT; then exit 0; fi
        green ""
        green "All NVIDIA functions are already bound to vfio-pci. Nothing to do."
        exit 0
    fi

    # ── Check: GPU function on something unexpected? ─────────────
    mixed=false
    for i in "''${!ALL_DEVS[@]}"; do
        dev="''${ALL_DEVS[$i]}"
        drv="''${ALL_DRIVERS[$i]}"
        # Only the GPU function (class 03) matters for this check
        class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
        if [ "$class" = "03" ] && [ "$drv" != "nvidia" ] && [ "$drv" != "vfio-pci" ] && [ "$drv" != "none" ]; then
            warn "GPU function $dev is bound to unexpected driver: $drv"
            mixed=true
        fi
    done
    if $mixed; then
        yellow "GPU in unexpected state. Continuing anyway..."
    fi

    # ── Check for displays actively driven by NVIDIA ──────────────
    info "Checking for displays actively driven by NVIDIA GPU..."
    HAS_DISPLAY=false
    if [ -d "/sys/bus/pci/devices/$GPU_BDF/drm" ]; then
        for card in /sys/bus/pci/devices/$GPU_BDF/drm/card*; do
            [ -d "$card" ] || continue
            for conn_dir in "$card"/card*-*; do
                [ -d "$conn_dir" ] || continue
                status=$(cat "$conn_dir/status" 2>/dev/null || echo "unknown")
                [ "$status" != "connected" ] && continue
                # Verify the connector actually drives a display (enabled + modes)
                enabled=$(cat "$conn_dir/enabled" 2>/dev/null || echo "disabled")
                modes=$(cat "$conn_dir/modes" 2>/dev/null | head -1 || true)
                if [ "$enabled" = "enabled" ] && [ -n "$modes" ]; then
                    conn_name=$(basename "$conn_dir")
                    yellow "Display $conn_name is ACTIVE on the NVIDIA GPU (mode: $modes)"
                    HAS_DISPLAY=true
                else
                    conn_name=$(basename "$conn_dir")
                    info "Connector $conn_name reports connected but is not enabled — skipping"
                fi
            done
        done
    fi
    $HAS_DISPLAY && $SILENT && { yellow "Display(s) actively driven by NVIDIA GPU"; exit 1; }
    $HAS_DISPLAY && ! $SILENT && yellow "Moving the GPU to VFIO will kill active displays immediately."

    # ── Check for processes using nvidia devices ─────────────────
    info "Checking for processes using NVIDIA devices..."
    # System daemons handled separately — filter them out
    IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"
    has_procs=false
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids=$(${psmisc}/bin/fuser "$nvdev" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            shown=false
            for pid in $pids; do
                pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
                if ! $shown; then echo ""; yellow "Processes using $nvdev:"; shown=true; fi
                has_procs=true
                echo "  PID $pid  ($pname)"
            done
        fi
    done
    for dev in "''${ALL_DEVS[@]}"; do
        pids=$(${psmisc}/bin/fuser "/sys/bus/pci/devices/$dev" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            shown=false
            for pid in $pids; do
                pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
                if ! $shown; then echo ""; yellow "Processes holding $dev:"; shown=true; fi
                has_procs=true
                echo "  PID $pid  ($pname)"
            done
        fi
    done

    # ── Check for active graphical sessions ──────────────────────
    HAS_SEAT=false
    if command -v loginctl &>/dev/null; then
        if loginctl list-sessions --no-legend 2>/dev/null | grep -v "tty" | grep -q "seat0"; then
            HAS_SEAT=true
        fi
    fi

    if ! $has_procs && ! $HAS_DISPLAY && ! $HAS_SEAT; then
        $SILENT || ok "No active users, displays, or processes on the NVIDIA GPU."
    fi

    # ── Blocking: ask user how to proceed ────────────────────────
    if $has_procs || $HAS_DISPLAY || $HAS_SEAT; then
        if $SILENT; then
            $has_procs && yellow "Processes holding NVIDIA devices"
            $HAS_DISPLAY && yellow "Display(s) actively driven by NVIDIA GPU"
            $HAS_SEAT && yellow "Active graphical sessions"
            exit 1
        fi
        echo ""
        yellow "──────────────────────────────────────────────────────"
        yellow "  The NVIDIA GPU is currently in use by the host."
        yellow "  Binding it to vfio-pci now will disrupt your desktop."
        yellow "──────────────────────────────────────────────────────"
        echo ""
        echo "  [f] Force  — kill processes & unbind immediately (risky)"
        echo "  [l] Logout — schedule binding; log out, then run gpu-vfio-apply"
        echo "  [c] Cancel — abort"
        echo ""
        read -rp "Choose [f/l/c]: " answer
        case "$answer" in
            [fF])
                warn "Forcing GPU unbind — this may crash your desktop."
                for nvdev in /dev/nvidia*; do
                    [ -e "$nvdev" ] || continue
                    ${psmisc}/bin/fuser -k "$nvdev" 2>/dev/null || true
                done
                for dev in "''${ALL_DEVS[@]}"; do
                    ${psmisc}/bin/fuser -k "/sys/bus/pci/devices/$dev" 2>/dev/null || true
                done
                sleep 1
                ok "Processes terminated."
                ;;
            [lL])
                mkdir -p /etc/gpu-switch
                echo "vfio" > /etc/gpu-switch/pending
                green ""
                green "GPU binding to vfio-pci scheduled for next logout."
                echo ""
                yellow "Steps to complete:"
                yellow "  1. Log out of your desktop session"
                yellow "  2. Press Ctrl+Alt+F2 to switch to a VT"
                yellow "  3. Log in as root"
                yellow "  4. Run:  gpu-vfio-apply"
                echo ""
                exit 0
                ;;
            *)
                red "Aborted."
                exit 1
                ;;
        esac
    fi

    # ── Stop NVIDIA services ─────────────────────────────────────
    info "Stopping NVIDIA services..."
    systemctl stop nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced stopped" || true
    systemctl stop nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd stopped" || true

    # ── Remove NVIDIA modules ────────────────────────────────────
    info "Unloading NVIDIA kernel modules..."
    for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia nvidia_wmi_ec_backlight; do
        if lsmod | grep -q "^$mod "; then
            if rmmod "$mod" 2>/dev/null; then
                ok "Removed module: $mod"
            else
                warn "Could not remove module: $mod (may be in use — force with rmmod -f if needed)"
            fi
        fi
    done
    sleep 0.5

    # ── Bind to vfio-pci ─────────────────────────────────────────
    info "Binding NVIDIA functions to vfio-pci..."

    # Ensure vfio-pci knows about these devices
    for dev in "''${ALL_DEVS[@]}"; do
        pci_id=$(${pciutils}/bin/lspci -ns "$dev" 2>/dev/null | awk '{print $3}')
        if [ -n "$pci_id" ]; then
            echo "$pci_id" | sed 's/:/ /' > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
        fi
    done

    for dev in "''${ALL_DEVS[@]}"; do
        info "Processing $dev..."

        # Set driver_override
        if ! echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null; then
            fail "Could not set driver_override for $dev"
            continue
        fi

        # Unbind from current driver
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [ -n "$cur_drv" ] && [ "$cur_drv" != "vfio-pci" ]; then
            echo "$dev" > "/sys/bus/pci/drivers/$cur_drv/unbind" 2>/dev/null || true
        fi

        # Trigger re-probe
        echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done

    sleep 1

    # ── Verify ───────────────────────────────────────────────────
    echo ""
    info "Verifying binding..."
    all_ok=true
    for dev in "''${ALL_DEVS[@]}"; do
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [ "$cur_drv" = "vfio-pci" ]; then
            ok "$dev  →  vfio-pci"
        else
            fail "$dev  →  $cur_drv  (expected vfio-pci)"
            all_ok=false
        fi
    done

    echo ""
    if $all_ok; then
        green "All NVIDIA functions successfully bound to vfio-pci."
        green "The GPU is ready for VM passthrough."
        echo ""
        yellow "To return the GPU to the host later, run:  gpu-to-host"
    else
        red "Some devices failed to bind. Check dmesg for details."
        exit 1
    fi
  '';

  # Return NVIDIA dGPU from vfio-pci back to nvidia host driver
    "gpu-to-host" = writeScriptBin "gpu-to-host" ''
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

    # ── Discover NVIDIA dGPU functions ───────────────────────────
    info "Discovering NVIDIA dGPU PCI functions..."

    GPU_BDF=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$GPU_BDF" ]; then
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

    if [ ''${#ALL_DEVS[@]} -eq 0 ]; then
        red "ERROR: No NVIDIA functions found on device $GPU_BUSDEV"
        exit 1
    fi

    # ── Show summary ─────────────────────────────────────────────
    echo ""
    info "Found ''${#ALL_DEVS[@]} NVIDIA device function(s):"
    for i in "''${!ALL_DEVS[@]}"; do
        desc=$(${pciutils}/bin/lspci -s "''${ALL_DEVS[$i]}" 2>/dev/null | cut -d' ' -f2-)
        printf "  %-13s  driver: %-10s  iommu_group: %-3s  %s\n" \
            "''${ALL_DEVS[$i]}" "''${ALL_DRIVERS[$i]}" "''${IOMMU_GROUPS[$i]}" "$desc"
    done

    # ── Check: already all on host drivers? ───────────────────────
    all_host=true
    for i in "''${!ALL_DEVS[@]}"; do
        drv="''${ALL_DRIVERS[$i]}"
        dev="''${ALL_DEVS[$i]}"
        if [ "$drv" = "vfio-pci" ] || [ "$drv" = "none" ]; then
            # Check if this is the GPU itself — it MUST be on nvidia
            class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
            if [ "$class" = "03" ]; then
                yellow "GPU function $dev is not on nvidia (driver: $drv)"
                all_host=false
            elif [ "$drv" = "vfio-pci" ]; then
                all_host=false
            fi
        fi
    done
    if $all_host; then
        if $SILENT; then exit 0; fi
        green ""
        green "All NVIDIA functions are on host drivers (GPU on nvidia)."
        info "Verifying NVIDIA services..."
        systemctl is-active --quiet nvidia-persistenced.service 2>/dev/null \
            || { systemctl start nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced started (was stopped)"; }
        systemctl is-active --quiet nvidia-powerd.service 2>/dev/null \
            || { systemctl start nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd started (was stopped)"; }
        ok "NVIDIA services are running."
        if [ -e /dev/nvidia0 ]; then
            ok "/dev/nvidia0 present"
        fi
        exit 0
    fi

    # ── Check: VM using the vfio device? ─────────────────────────
    info "Checking if a running VM is using this GPU..."
    vm_active=false
    for iommu in $(printf '%s\n' "''${IOMMU_GROUPS[@]}" | sort -u); do
        if [ -e "/dev/vfio/$iommu" ]; then
            if ${psmisc}/bin/fuser "/dev/vfio/$iommu" >/dev/null 2>&1; then
                vm_active=true
                red "ERROR: IOMMU group $iommu is in use by a running VM!"
                red "  /dev/vfio/$iommu is held by:"
                ${psmisc}/bin/fuser -v "/dev/vfio/$iommu" 2>&1 | sed 's/^/  /' >&2
            fi
        fi
    done
    if $vm_active; then
        red ""
        red "Aborting: shut down the VM first, then re-run this script."
        exit 1
    fi
    ok "No VM is using the GPU."

    # ── Ensure nvidia modules are loaded ─────────────────────────
    info "Ensuring NVIDIA kernel modules are loaded..."
    for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
        if ! lsmod | grep -q "^$mod "; then
            modprobe "$mod" 2>/dev/null && ok "Loaded module: $mod" || warn "Could not load $mod (will try after binding)"
        else
            ok "Module $mod already loaded"
        fi
    done

    # ── Clear driver_override, unbind from vfio-pci, re-probe ────
    info "Returning GPU to the nvidia host driver..."

    # Remove the PCI IDs that gpu-to-vfio added to vfio-pci's new_id
    for dev in "''${ALL_DEVS[@]}"; do
        pci_id=$(${pciutils}/bin/lspci -ns "$dev" 2>/dev/null | awk '{print $3}')
        if [ -n "$pci_id" ]; then
            echo "$pci_id" | sed 's/:/ /' > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
        fi
    done

    for dev in "''${ALL_DEVS[@]}"; do
        info "Processing $dev..."

        # Clear driver_override
        echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true

        # Unbind from vfio-pci
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
        if [ "$cur_drv" = "vfio-pci" ]; then
            echo "$dev" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        fi

        # Trigger re-probe
        echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done

    sleep 2

    # ── If any device is still unbound, try loading nvidia and re-probe ──
    for dev in "''${ALL_DEVS[@]}"; do
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [ "$cur_drv" = "none" ]; then
            warn "$dev has no driver. Loading nvidia modules and retrying..."
            modprobe nvidia 2>/dev/null || true
            modprobe nvidia_drm 2>/dev/null || true
            sleep 0.5
            echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        fi
    done

    sleep 1

    # ── Verify ───────────────────────────────────────────────────
    echo ""
    info "Verifying binding..."
    all_ok=true
    for dev in "''${ALL_DEVS[@]}"; do
        cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
        if [ "$class" = "03" ]; then
            # GPU function: must be nvidia
            if [ "$cur_drv" = "nvidia" ]; then
                ok "$dev  →  nvidia"
            else
                fail "$dev  →  $cur_drv  (expected nvidia)"
                all_ok=false
            fi
        else
            # Audio/USB/etc: any host driver is fine
            if [ "$cur_drv" != "vfio-pci" ] && [ "$cur_drv" != "none" ]; then
                ok "$dev  →  $cur_drv"
            else
                fail "$dev  →  $cur_drv  (expected host driver)"
                all_ok=false
            fi
        fi
    done

    # ── Start NVIDIA services ────────────────────────────────────
    info "Starting NVIDIA services..."
    systemctl start nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced started" || true
    systemctl start nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd started" || true

    # ── Runtime PM ───────────────────────────────────────────────
    for dev in "''${ALL_DEVS[@]}"; do
        pm_control="/sys/bus/pci/devices/$dev/power/control"
        if [ -w "$pm_control" ]; then
            echo "auto" > "$pm_control" 2>/dev/null || true
        fi
    done

    # ── Quick health check ───────────────────────────────────────
    echo ""
    if [ -e /dev/nvidia0 ]; then
        ok "/dev/nvidia0 exists"
    else
        warn "/dev/nvidia0 not found — GPU may need a few seconds to initialize"
    fi

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi -L &>/dev/null 2>&1; then
            ok "nvidia-smi reports GPU visible"
        else
            warn "nvidia-smi could not detect GPU (ignore if X11/Wayland is not running)"
        fi
    fi

    echo ""
    if $all_ok; then
        green "GPU successfully returned to the host nvidia driver."
        yellow "You may need to restart your display manager if you want X11/Wayland to use it:"
        yellow "  sudo systemctl restart display-manager.service"
    else
        red "Some devices failed to bind to nvidia. Check dmesg for errors."
        red "You may need to reboot."
        exit 1
    fi
  '';

  # Show current GPU VFIO/nvidia binding status
  "gpu-vfio-status" = writeScriptBin "gpu-vfio-status" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    cyan()   { echo -e "\e[36m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }

    echo ""
    cyan "═════════════════════════════════════════════"
    cyan "  GPU VFIO / Host Binding Status"
    cyan "═════════════════════════════════════════════"
    echo ""

    # ── NVIDIA PCI devices ───────────────────────────────────────
    echo "── NVIDIA dGPU PCI Devices ──"
    echo ""

    FOUND=false
    while IFS= read -r line; do
        FOUND=true
        bdf=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2-)
        vendor_id=$(${pciutils}/bin/lspci -ns "$bdf" 2>/dev/null | awk '{print $3}' || echo "unknown")

        drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        iommu=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")

        # Color by driver
        case "$drv" in
            nvidia)   drv_color="\e[32m" ;;  # green — host
            vfio-pci) drv_color="\e[35m" ;;  # purple — VM-ready
            *)        drv_color="\e[31m" ;;  # red — unknown
        esac

        printf "  \e[1m%-37s\e[0m  vendor:device = %s\n" "$bdf" "$vendor_id"
        printf "    %s\n" "$desc"
        printf "    driver:       ''${drv_color}%s\e[0m\n" "$drv"
        printf "    iommu_group:  %s\n" "$iommu"

        # Check runtime PM status
        pm_status=$(cat "/sys/bus/pci/devices/$bdf/power/runtime_status" 2>/dev/null || echo "unknown")
        printf "    pm_status:    %s\n" "$pm_status"

        # Show IOMMU group peers
        iommu_dir="/sys/kernel/iommu_groups/$iommu/devices" 2>/dev/null
        if [ -d "$iommu_dir" ]; then
            peers=$(ls "$iommu_dir" 2>/dev/null | grep -v "''${bdf##0000:}" || true)
            if [ -n "$peers" ]; then
                printf "    iommu_peers:  %s\n" "$peers"
            fi
        fi
        echo ""
    done < <(${pciutils}/bin/lspci -D -d 10DE: 2>/dev/null)

    if ! $FOUND; then
        yellow "  No NVIDIA PCI devices found."
        yellow "  (GPU may be hard-disabled via ASUS dgpu_disable, or absent.)"
        echo ""
    fi

    # ── NVIDIA kernel modules ────────────────────────────────────
    echo "── NVIDIA Kernel Modules ──"
    echo ""
    has_mod=false
    for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        if lsmod 2>/dev/null | grep -q "^$mod "; then
            count=$(lsmod 2>/dev/null | grep "^$mod " | awk '{print $3}')
            printf "  \e[32m%-20s  loaded  (used by: %s)\e[0m\n" "$mod" "''${count:-0}"
            has_mod=true
        fi
    done
    if ! $has_mod; then
        echo "  (none loaded)"
    fi
    echo ""

    # ── VFIO kernel modules ──────────────────────────────────────
    echo "── VFIO Kernel Modules ──"
    echo ""
    has_mod=false
    for mod in vfio_pci vfio_pci_core vfio_iommu_type1 vfio; do
        if lsmod 2>/dev/null | grep -q "^$mod "; then
            count=$(lsmod 2>/dev/null | grep "^$mod " | awk '{print $3}')
            printf "  \e[35m%-20s  loaded  (used by: %s)\e[0m\n" "$mod" "''${count:-0}"
            has_mod=true
        fi
    done
    if ! $has_mod; then
        echo "  (none loaded)"
    fi
    echo ""

    # ── VM activity check (requires root) ────────────────────────
    echo "── VM Activity ──"
    echo ""
    if [ "$EUID" -eq 0 ]; then
        vm_found=false
        for vfio_dev in /dev/vfio/*; do
            [ -e "$vfio_dev" ] || continue
            iommu=$(basename "$vfio_dev")
            if ${psmisc}/bin/fuser "$vfio_dev" >/dev/null 2>&1; then
                vm_found=true
                printf "  \e[33m/dev/vfio/%s  IN USE by VM:\e[0m\n" "$iommu"
                ${psmisc}/bin/fuser -v "$vfio_dev" 2>&1 | sed 's/^/    /'
            fi
        done
        if ! $vm_found; then
            echo "  No VM seems to be using any VFIO device."
        fi
    else
        yellow "  Run as root for VM activity check."
    fi
    echo ""

    # ── Processes using nvidia devices ───────────────────────────
    echo "── Processes Using NVIDIA Devices ──"
    echo ""
    has_proc=false
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        if [ "$EUID" -eq 0 ]; then
            pids=$(${psmisc}/bin/fuser "$nvdev" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                has_proc=true
                for pid in $pids; do
                    pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
                    user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
                    printf "  %-8s  PID %-6s  %s\n" "$user" "$pid" "$pname"
                done
            fi
        else
            has_proc=true
            yellow "  Run as root to check."
            break
        fi
    done
    if ! $has_proc; then
        echo "  (none)"
    fi
    echo ""

    # ── DRM connectors (displays) ────────────────────────────────
    echo "── Displays Connected to NVIDIA ──"
    echo ""
    gpu_bdf=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$gpu_bdf" ] && [ -d "/sys/bus/pci/devices/$gpu_bdf/drm" ]; then
        has_conn=false
        for card in /sys/bus/pci/devices/$gpu_bdf/drm/card*; do
            [ -d "$card" ] || continue
            for conn in "$card"/card*-*/status; do
                [ -f "$conn" ] || continue
                conn_name=$(basename "$(dirname "$conn")")
                status=$(cat "$conn" 2>/dev/null)
                if [ "$status" = "connected" ]; then
                    has_conn=true
                    mode=$(cat "$(dirname "$conn")/modes" 2>/dev/null | head -1 || echo "?")
                    printf "  \e[33m%-10s  %-10s  %s\e[0m\n" "$conn_name" "$status" "$mode"
                else
                    printf "  %-10s  %s\n" "$conn_name" "$status"
                fi
            done
        done
        if ! $has_conn; then
            echo "  No displays connected."
        fi
    else
        echo "  NVIDIA DRM not available (GPU not on nvidia driver)."
    fi
    echo ""

    # ── Services ─────────────────────────────────────────────────
    echo "── NVIDIA Services ──"
    echo ""
    for svc in nvidia-persistenced.service nvidia-powerd.service; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  \e[32m%-35s active\e[0m\n" "$svc"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            printf "  \e[33m%-35s enabled but inactive\e[0m\n" "$svc"
        else
            printf "  %-35s not active\n" "$svc"
        fi
    done
    echo ""

    # ── Kernel cmdline VFIO params ───────────────────────────────
    echo "── Kernel Cmdline VFIO Settings ──"
    echo ""
    grep -oP 'vfio[^ ]*' /proc/cmdline 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    echo ""

    # ── Verdict ──────────────────────────────────────────────────
    echo "── Summary ──"
    echo ""
    if [ -n "$gpu_bdf" ]; then
        drv=$(readlink "/sys/bus/pci/devices/$gpu_bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        case "$drv" in
            nvidia)
                green "  GPU is bound to nvidia — ready for host use."
                green "  To pass to a VM:    gpu-to-vfio"
                ;;
            vfio-pci)
                green "  GPU is bound to vfio-pci — ready for VM passthrough."
                green "  To return to host:  gpu-to-host"
                ;;
            *)
                yellow "  GPU is on '$drv' — unexpected state."
                ;;
        esac
    else
        yellow "  Could not detect GPU state."
    fi
    echo ""
  '';

  # Apply a pending GPU binding after logout (run from a VT after logging out)
  "gpu-vfio-apply" = writeScriptBin "gpu-vfio-apply" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    PENDING="/etc/gpu-switch/pending"

    if [ ! -f "$PENDING" ]; then
        red "No pending GPU switch found."
        echo "Run gpu-to-vfio or gpu-to-host first to schedule a switch."
        exit 1
    fi

    # ── Warn about active graphical sessions ─────────────────────
    if command -v loginctl &>/dev/null; then
        ACTIVE=$(loginctl list-sessions --no-legend 2>/dev/null | grep -v "tty" | grep "seat0" | wc -l)
        if [ "$ACTIVE" -gt 0 ]; then
            yellow "WARNING: ''${ACTIVE} active graphical session(s) detected."
            yellow "It's safer to log out of your desktop first."
            yellow "Then switch to a VT (Ctrl+Alt+F2), log in as root, and run this again."
            echo ""
            read -rp "Proceed anyway? [y/N] " ans
            [[ "$ans" =~ ^[Yy] ]] || exit 1
        fi
    fi

    # ── Read and apply ───────────────────────────────────────────
    MODE=$(cat "$PENDING")
    rm -f "$PENDING"

    info "Applying pending GPU switch: ''${MODE}"
    case "$MODE" in
        vfio)
            info "Binding GPU to vfio-pci..."
            exec gpu-to-vfio
            ;;
        host)
            info "Returning GPU to nvidia host driver..."
            exec gpu-to-host
            ;;
        *)
            red "Unknown pending mode: ''${MODE}"
            exit 1
            ;;
    esac
  '';
}
