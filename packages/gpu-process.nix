{
  writeScriptBin,
  psmisc,
  pciutils,
}: {
  # List processes using NVIDIA GPU (excludes nvidia-powerd/persistenced)
  "gpu-process-check" = writeScriptBin "gpu-process-check" ''
    #!/usr/bin/env bash
    set -euo pipefail

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    cyan()   { echo -e "\e[36m$*\e[0m" >&2; }

    IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"

    echo ""
    cyan "── Processes Using NVIDIA Devices ──"
    echo ""

    has_any=false

    # /dev/nvidia* devices
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids=$(${psmisc}/bin/fuser "$nvdev" 2>/dev/null || true)
        [ -z "$pids" ] && continue
        shown=false
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            if ! $shown; then echo "  $nvdev:"; shown=true; fi
            printf "    %-10s  PID %-8s  %s\n" "$user" "$pid" "$pname"
            has_any=true
        done
    done

    # dGPU sysfs paths
    while IFS= read -r line; do
        bdf=$(echo "$line" | awk '{print $1}')
        pids=$(${psmisc}/bin/fuser "/sys/bus/pci/devices/$bdf" 2>/dev/null || true)
        [ -z "$pids" ] && continue
        shown=false
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            if ! $shown; then echo "  $bdf:"; shown=true; fi
            printf "    %-10s  PID %-8s  %s\n" "$user" "$pid" "$pname"
            has_any=true
        done
    done < <(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk '{print $1}')

    if ! $has_any; then
        echo "  (no user processes found)"
    fi

    echo ""
    cyan "── NVIDIA Services ──"
    echo ""
    for svc in nvidia-persistenced.service nvidia-powerd.service; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "  \e[32m%-35s active\e[0m\n" "$svc"
        else
            printf "  \e[33m%-35s stopped\e[0m\n" "$svc"
        fi
    done
    echo ""

    cyan "── NVIDIA DRM Connectors ──"
    echo ""
    gpu_bdf=$(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$gpu_bdf" ] && [ -d "/sys/bus/pci/devices/$gpu_bdf/drm" ]; then
        has_conn=false
        for card in /sys/bus/pci/devices/$gpu_bdf/drm/card*; do
            [ -d "$card" ] || continue
            for conn_dir in "$card"/card*-*; do
                [ -d "$conn_dir" ] || continue
                status=$(cat "$conn_dir/status" 2>/dev/null || echo "unknown")
                conn_name=$(basename "$conn_dir")
                enabled=$(cat "$conn_dir/enabled" 2>/dev/null || echo "disabled")
                modes=$(cat "$conn_dir/modes" 2>/dev/null | head -1 || true)
                if [ "$status" = "connected" ] && [ "$enabled" = "enabled" ] && [ -n "$modes" ]; then
                    printf "  \e[33m%-15s %-10s  mode: %s\e[0m\n" "$conn_name" "ACTIVE" "$modes"
                elif [ "$status" = "connected" ]; then
                    printf "  %-15s %-10s (iGPU / PRIME)\n" "$conn_name" "$status"
                else
                    printf "  %-15s %-10s\n" "$conn_name" "$status"
                fi
                has_conn=true
            done
        done
        $has_conn || echo "  (no DRM connectors found)"
    else
        echo "  NVIDIA DRM not available (GPU not on nvidia driver)."
    fi
    echo ""
  '';

  # List NVIDIA processes, then prompt to kill them
  "gpu-process-kill" = writeScriptBin "gpu-process-kill" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    cyan()   { echo -e "\e[36m$*\e[0m" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"

    echo ""
    cyan "── Checking for Processes Using NVIDIA ──"
    echo ""

    declare -A procs
    has_any=false

    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids=$(${psmisc}/bin/fuser "$nvdev" 2>/dev/null || true)
        [ -z "$pids" ] && continue
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
            printf "  %-10s  PID %-8s  %s\n" "$user" "$pid" "$pname"
            procs["$pid"]="$pname"
            has_any=true
        done
    done

    while IFS= read -r line; do
        bdf=$(echo "$line" | awk '{print $1}')
        pids=$(${psmisc}/bin/fuser "/sys/bus/pci/devices/$bdf" 2>/dev/null || true)
        [ -z "$pids" ] && continue
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            # Already shown? skip duplicate
            [ -n "''${procs[$pid]:-}" ] && continue
            user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
            printf "  %-10s  PID %-8s  %s\n" "$user" "$pid" "$pname"
            procs["$pid"]="$pname"
            has_any=true
        done
    done < <(${pciutils}/bin/lspci -D -d 10DE::0300 2>/dev/null | awk '{print $1}')

    if ! $has_any; then
        green "  No user processes found on NVIDIA devices."
        exit 0
    fi

    echo ""
    read -rp "Terminate these ''${#procs[@]} process(es)? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        yellow "Aborted."
        exit 0
    fi

    for pid in "''${!procs[@]}"; do
        if kill -9 "$pid" 2>/dev/null; then
            ok "Killed PID $pid (''${procs[$pid]})"
        else
            warn "Failed to kill PID $pid"
        fi
    done
    echo ""
    green "Done."
  '';
}
