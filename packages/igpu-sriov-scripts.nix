{
  writeScriptBin,
  psmisc,
  pciutils,
}: let
  helpers = ''
    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    cyan()   { echo -e "\e[36m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }
    fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }
    warn()   { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }
  '';
  # Reusable VM-guard check; returns 0 if no VM is using any VF, 1 otherwise.
  # Expects CUR_VFS to be set to the current sriov_numvfs value.
  vmGuardSnippet = ''
    # ── Guard: check if any VF is in use by a running VM ────────
    if [ "$CUR_VFS" -gt 0 ]; then
      info "Checking if any VF is in use by a running VM..."
      for i in $(seq 1 "$CUR_VFS"); do
        VF=$(printf "0000:00:02.%d" "$i")
        if [ ! -d "/sys/bus/pci/devices/$VF" ]; then continue; fi
        IOMMU=$(basename "$(readlink "/sys/bus/pci/devices/$VF/iommu_group" 2>/dev/null)" 2>/dev/null || echo "")
        if [ -z "$IOMMU" ] || [ "$IOMMU" = "?" ]; then continue; fi
        if [ -e "/dev/vfio/$IOMMU" ] && ${psmisc}/bin/fuser "/dev/vfio/$IOMMU" >/dev/null 2>&1; then
          red "ERROR: VF $VF (IOMMU group $IOMMU) is in use by a running VM!"
          ${psmisc}/bin/fuser -v "/dev/vfio/$IOMMU" 2>&1 | sed 's/^/    /' >&2
          exit 1
        fi
      done
      ok "No VFs in use by a VM."
    fi
  '';
in {
  # Spin up N iGPU SR-IOV Virtual Functions and bind them to vfio-pci.
  # Usage: igpu-vf-up [N]   (default 1, 0 = destroy all)
  "igpu-vf-up" = writeScriptBin "igpu-vf-up" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${helpers}

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    PF="0000:00:02.0"
    SRIOV_SYSFS="/sys/bus/pci/devices/$PF/sriov_numvfs"
    COUNT="''${1:-1}"

    if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 0 ]; then
        red "Usage: igpu-vf-up [COUNT]   (COUNT >= 0, default 1)"
        exit 1
    fi

    # Wait up to 10 seconds for the driver to expose the sysfs node
    for i in {1..10}; do
        if [ -f "$SRIOV_SYSFS" ]; then break; fi
        sleep 1
    done
    if [ ! -f "$SRIOV_SYSFS" ]; then
        red "ERROR: sriov_numvfs not found at $SRIOV_SYSFS"
        red "Is the out-of-tree i915/xe SR-IOV module loaded?"
        exit 1
    fi

    CUR_VFS=$(cat "$SRIOV_SYSFS")
    MAX_VFS=$(cat "/sys/bus/pci/devices/$PF/sriov_totalvfs" 2>/dev/null || echo "?")
    info "Current VFs: $CUR_VFS  |  Max VFs: $MAX_VFS"

    if [ "$CUR_VFS" -eq "$COUNT" ]; then
        green "Already have $COUNT VF(s). Nothing to do."
        exit 0
    fi

    if [ "$COUNT" -gt "$MAX_VFS" ] 2>/dev/null; then
        red "Requested $COUNT VF(s) but max is $MAX_VFS."
        exit 1
    fi

    ${vmGuardSnippet}

    # If reducing or changing count, destroy all VFs first
    if [ "$CUR_VFS" -gt 0 ]; then
      info "Destroying existing VFs..."
      echo 0 > "$SRIOV_SYSFS"
      sleep 1
    fi

    if [ "$COUNT" -eq 0 ]; then
      green "All VFs destroyed."
      exit 0
    fi

    # ── Create VFs ───────────────────────────────────────────────
    info "Creating $COUNT VF(s)..."
    echo "$COUNT" > "$SRIOV_SYSFS"
    sleep 2

    # Verify VFs appeared
    NEW_VFS=$(cat "$SRIOV_SYSFS")
    if [ "$NEW_VFS" -ne "$COUNT" ]; then
      fail "Expected $COUNT VF(s) but kernel reports $NEW_VFS. Check dmesg."
      exit 1
    fi

    # ── Bind VFs to vfio-pci ─────────────────────────────────────
    modprobe vfio-pci 2>/dev/null || true

    all_ok=true
    for i in $(seq 1 "$COUNT"); do
      VF=$(printf "0000:00:02.%d" "$i")
      if [ ! -d "/sys/bus/pci/devices/$VF" ]; then
        fail "VF $VF not found in sysfs. Kernel may not have created it."
        all_ok=false
        continue
      fi

      info "Binding $VF to vfio-pci..."

      # Unbind from current driver (i915 or xe)
      CUR_DRV=$(readlink "/sys/bus/pci/devices/$VF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
      if [ -n "$CUR_DRV" ] && [ "$CUR_DRV" != "vfio-pci" ]; then
        echo "$VF" > "/sys/bus/pci/drivers/$CUR_DRV/unbind" 2>/dev/null || true
      fi

      # Set driver_override and bind to vfio-pci
      echo "vfio-pci" > "/sys/bus/pci/devices/$VF/driver_override" 2>/dev/null || true
      echo "$VF" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
        fail "Could not bind $VF to vfio-pci. Check dmesg."
        all_ok=false
        continue
      }
      echo "" > "/sys/bus/pci/devices/$VF/driver_override" 2>/dev/null || true

      sleep 0.3

      # Verify
      FINAL_DRV=$(readlink "/sys/bus/pci/devices/$VF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
      if [ "$FINAL_DRV" = "vfio-pci" ]; then
        IOMMU=$(basename "$(readlink "/sys/bus/pci/devices/$VF/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")
        ok "$VF  →  vfio-pci  (iommu group $IOMMU)"
      else
        fail "$VF  →  $FINAL_DRV  (expected vfio-pci)"
        all_ok=false
      fi
    done

    echo ""
    if $all_ok; then
      green "All $COUNT VF(s) created and bound to vfio-pci."
      green "Ready for VM passthrough."
      echo ""
      yellow "To destroy VFs when done:  igpu-vf-down"
    else
      red "Some VFs failed to bind. Check dmesg for details."
      exit 1
    fi
  '';

  # Destroy all iGPU SR-IOV Virtual Functions.
  # Refuses to run if any VF is in use by a running VM.
  "igpu-vf-down" = writeScriptBin "igpu-vf-down" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${helpers}

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    PF="0000:00:02.0"
    SRIOV_SYSFS="/sys/bus/pci/devices/$PF/sriov_numvfs"

    if [ ! -f "$SRIOV_SYSFS" ]; then
      red "ERROR: sriov_numvfs not found."
      exit 1
    fi

    CUR_VFS=$(cat "$SRIOV_SYSFS")
    if [ "$CUR_VFS" -eq 0 ]; then
      green "No VFs to destroy. Already clean."
      exit 0
    fi

    ${vmGuardSnippet}

    # ── Unbind VFs from vfio-pci ─────────────────────────────────
    info "Unbinding VFs from vfio-pci..."
    for i in $(seq 1 "$CUR_VFS"); do
      VF=$(printf "0000:00:02.%d" "$i")
      if [ ! -d "/sys/bus/pci/devices/$VF" ]; then continue; fi

      echo "" > "/sys/bus/pci/devices/$VF/driver_override" 2>/dev/null || true

      CUR_DRV=$(readlink "/sys/bus/pci/devices/$VF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
      if [ "$CUR_DRV" = "vfio-pci" ]; then
        echo "$VF" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        ok "Unbound $VF from vfio-pci"
      fi
    done

    # ── Destroy all VFs ──────────────────────────────────────────
    info "Destroying all $CUR_VFS VF(s)..."
    echo 0 > "$SRIOV_SYSFS"
    sleep 1

    # ── Verify ───────────────────────────────────────────────────
    CUR_VFS=$(cat "$SRIOV_SYSFS")
    if [ "$CUR_VFS" -eq 0 ]; then
      green "All VFs destroyed. iGPU is fully host-only."
    else
      fail "$CUR_VFS VF(s) remain. Something went wrong."
      exit 1
    fi
  '';

  # Show current iGPU SR-IOV VF status.
  "igpu-vf-status" = writeScriptBin "igpu-vf-status" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${helpers}

    PF="0000:00:02.0"
    SRIOV_SYSFS="/sys/bus/pci/devices/$PF/sriov_numvfs"

    echo ""
    cyan "═════════════════════════════════════════════"
    cyan "  iGPU SR-IOV VF Status"
    cyan "═════════════════════════════════════════════"
    echo ""

    if [ ! -f "$SRIOV_SYSFS" ]; then
      yellow "  SR-IOV not available. Is i915-sriov or xe-sriov module loaded?"
      echo ""
      exit 0
    fi

    CUR_VFS=$(cat "$SRIOV_SYSFS")
    MAX_VFS=$(cat "/sys/bus/pci/devices/$PF/sriov_totalvfs" 2>/dev/null || echo "?")
    PF_DRV=$(readlink "/sys/bus/pci/devices/$PF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    PF_DESC=$(${pciutils}/bin/lspci -s "$PF" 2>/dev/null | cut -d' ' -f2- || echo "?")

    echo "── Physical Function (PF) ──"
    echo ""
    printf "  %-13s  driver: %-6s  %s\n" "$PF" "$PF_DRV" "$PF_DESC"
    printf "  VF count:   %d / %s\n" "$CUR_VFS" "$MAX_VFS"
    echo ""

    if [ "$CUR_VFS" -eq 0 ]; then
      yellow "  No VFs spawned."
      echo ""
    else
      echo "── Virtual Functions ──"
      echo ""
      for i in $(seq 1 "$CUR_VFS"); do
        VF=$(printf "0000:00:02.%d" "$i")
        if [ ! -d "/sys/bus/pci/devices/$VF" ]; then
          printf "  %-13s  (not found in sysfs)\n" "$VF"
          continue
        fi
        VF_DESC=$(${pciutils}/bin/lspci -s "$VF" 2>/dev/null | cut -d' ' -f2- || echo "?")
        VF_DRV=$(readlink "/sys/bus/pci/devices/$VF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        IOMMU=$(basename "$(readlink "/sys/bus/pci/devices/$VF/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")

        case "$VF_DRV" in
          vfio-pci) drv_color="\e[35m" ;;
          i915|xe)  drv_color="\e[33m" ;;
          *)        drv_color="\e[31m" ;;
        esac

        printf "  \e[1m%-13s\e[0m  driver: ''${drv_color}%-10s\e[0m  iommu: %s\n" "$VF" "$VF_DRV" "$IOMMU"
        printf "    %s\n" "$VF_DESC"

        # VM guard check (requires root)
        if [ "$EUID" -eq 0 ] && [ -n "$IOMMU" ] && [ "$IOMMU" != "?" ] && [ -e "/dev/vfio/$IOMMU" ]; then
          if ${psmisc}/bin/fuser "/dev/vfio/$IOMMU" >/dev/null 2>&1; then
            printf "    \e[33mIN USE BY VM:\e[0m\n"
            ${psmisc}/bin/fuser -v "/dev/vfio/$IOMMU" 2>&1 | sed 's/^/      /'
          fi
        fi
        echo ""
      done
    fi

    echo "── Commands ──"
    echo ""
    echo "  igpu-vf-up [N]     Create N VFs and bind to vfio-pci"
    echo "  igpu-vf-down       Destroy all VFs  (refuses if VM is using them)"
    echo "  igpu-vf-status     Show this status"
    echo ""
  '';
}
