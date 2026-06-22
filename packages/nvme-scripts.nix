{
  writeScriptBin,
  psmisc,
  coreutils,
  findutils,
  gnugrep,
  gawk,
}: {
  # Return the NVMe drive (0000:02:00.0) from the VM back to the host
  "nvme-to-host" = writeScriptBin "nvme-to-host" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }
    fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    PCI_DEV="0000:02:00.0"

    # ── Idempotency: already on nvme? ────────────────────────────
    CUR_DRV=$(readlink "/sys/bus/pci/devices/$PCI_DEV/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$CUR_DRV" = "nvme" ]; then
        green "Drive $PCI_DEV is already on the nvme host driver. Nothing to do."
        exit 0
    fi

    # ── VM guard ─────────────────────────────────────────────────
    if [ -e "/sys/bus/pci/devices/$PCI_DEV/iommu_group" ]; then
        IOMMU_GROUP=$(basename "$(readlink /sys/bus/pci/devices/$PCI_DEV/iommu_group)")
        if [ -e "/dev/vfio/$IOMMU_GROUP" ] && ${psmisc}/bin/fuser "/dev/vfio/$IOMMU_GROUP" >/dev/null 2>&1; then
            red "ERROR: Drive $PCI_DEV is currently in use by a running VM!"
            red "Aborting to prevent guest data loss and PCIe bus freeze."
            exit 1
        fi
    fi
    ok "Drive is idle, no VM using it."

    # ── Return to host ───────────────────────────────────────────
    info "Returning $PCI_DEV to the nvme host driver..."
    echo "" > "/sys/bus/pci/devices/$PCI_DEV/driver_override"
    echo "$PCI_DEV" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "$PCI_DEV" > /sys/bus/pci/drivers_probe
    sleep 1

    # ── Verify ───────────────────────────────────────────────────
    CUR_DRV=$(readlink "/sys/bus/pci/devices/$PCI_DEV/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$CUR_DRV" = "nvme" ]; then
        green "Drive $PCI_DEV successfully returned to nvme driver."
        if [ -b /dev/nvme0 ]; then
            ok "Block device /dev/nvme0 is visible."
        fi
    else
        fail "Drive $PCI_DEV is on '$CUR_DRV' — expected nvme."
        red "Check dmesg for errors."
        exit 1
    fi
  '';

  # Isolate the NVMe drive onto vfio-pci for VM passthrough
  "nvme-to-vm" = writeScriptBin "nvme-to-vm" ''
    #!/usr/bin/env bash
    set -euo pipefail

    red()    { echo -e "\e[31m$*\e[0m" >&2; }
    green()  { echo -e "\e[32m$*\e[0m" >&2; }
    yellow() { echo -e "\e[33m$*\e[0m" >&2; }
    info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
    ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }
    fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }

    if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

    PCI_DEV="0000:02:00.0"

    # ── Idempotency: already on vfio-pci? ────────────────────────
    CUR_DRV=$(readlink "/sys/bus/pci/devices/$PCI_DEV/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$CUR_DRV" = "vfio-pci" ]; then
        green "Drive $PCI_DEV is already bound to vfio-pci. Nothing to do."
        exit 0
    fi

    # ── Find all NVMe block devices (all namespaces) ─────────────
    BLOCK_DEVS=$(${findutils}/bin/find /sys/bus/pci/devices/$PCI_DEV/ -name "nvme*n[0-9]*" -not -name "*p[0-9]*" 2>/dev/null | ${coreutils}/bin/basename -a 2>/dev/null || true)

    # ── Check for active mounts on ANY namespace ─────────────────
    if [ -n "$BLOCK_DEVS" ]; then
        has_mounts=false
        for blk in $BLOCK_DEVS; do
            if ${gnugrep}/bin/grep -q "/dev/$blk" /proc/mounts 2>/dev/null; then
                has_mounts=true
                echo ""
                red "ERROR: Drive $PCI_DEV ($blk) has active mounts on the host!"
                echo "Please unmount the following targets before running this script:" >&2
                ${gnugrep}/bin/grep "/dev/$blk" /proc/mounts | ${gawk}/bin/awk '{print "  -> " $2}' >&2
            fi
        done
        if $has_mounts; then
            echo ""
            exit 1
        fi
    fi
    ok "No active mounts found on NVMe drive."

    # ── Isolate to vfio-pci ──────────────────────────────────────
    info "Isolating $PCI_DEV for VM passthrough..."
    echo "vfio-pci" > "/sys/bus/pci/devices/$PCI_DEV/driver_override"
    echo "$PCI_DEV" > /sys/bus/pci/drivers/nvme/unbind 2>/dev/null || true
    echo "$PCI_DEV" > /sys/bus/pci/drivers_probe
    sleep 1

    # ── Verify ───────────────────────────────────────────────────
    CUR_DRV=$(readlink "/sys/bus/pci/devices/$PCI_DEV/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$CUR_DRV" = "vfio-pci" ]; then
        green "Drive $PCI_DEV successfully bound to vfio-pci."
        green "The NVMe drive is ready for VM passthrough."
    else
        fail "Drive $PCI_DEV is on '$CUR_DRV' — expected vfio-pci."
        red "Check dmesg for errors."
        exit 1
    fi
  '';
}
