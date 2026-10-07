#!/usr/bin/env bash
# Shrink (or restore) BAR1 on the NVIDIA dGPU so a passed-through 64-bit BAR is
# small enough for QEMU to place in the guest.
#
#   sudo ./shrink-gpu-bar.sh            # 1 GiB  (default)
#   sudo ./shrink-gpu-bar.sh 2147483648 # 2 GiB
#   sudo ./shrink-gpu-bar.sh 17179869184# back to 16 GiB
#
# Why: with BAR1 at 16 GiB, QEMU crashes while placing it in the guest:
#     kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed, slot=13,
#       start=0x8508000000000000, size=0x400000000: Invalid argument
# Supported sizes on this card (from resource1_resize / lspci):
#     64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB
#
# BAR1 is a hardware size register, so the device must be unbound while it is
# written. The GPU is on vfio-pci and unused by the host, so this is safe here;
# it would NOT be safe with a live display driver attached.
set -euo pipefail

BDF=${BDF:-0000:01:00.0}
WANT=${1:-1073741824}          # 1 GiB
DEV=/sys/bus/pci/devices/$BDF
DRV=vfio-pci

die() { echo "STOP: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -d "$DEV" ] || die "no such PCI device: $BDF"

bar1_size() { # bytes, from the resource file's BAR1 line
  awk 'NR==2{split($2,e,"x"); if ($1=="0x0000000000000000") {print 0; exit}
       printf "%d", strtonum(e)-strtonum($1)+1}' "$DEV/resource" 2>/dev/null \
    || awk 'NR==2{print $1" - "$2}' "$DEV/resource"
}
show() {
  echo "   BAR1: $(awk 'NR==2{print $1" - "$2}' "$DEV/resource")"
  echo "   resize mask: $(cat "$DEV/resource1_resize" 2>/dev/null)"
}

echo "== before =="
echo "   driver: $(basename "$(readlink -f "$DEV/driver" 2>/dev/null)" 2>/dev/null || echo none)"
show

# The size must be one the card advertises. Check the bitmask if we can read it.
mask=$(cat "$DEV/resource1_resize" 2>/dev/null || echo "")
if [ -n "$mask" ]; then
  # bit N set <=> size 2^(N+6) bytes supported  (64MB = bit 6)
  bit=$(python3 -c "
import sys
w=$WANT
b=w.bit_length()-1-6
print(b if b>=0 else -1)
")
  if [ "$bit" -ge 0 ]; then
    if ! python3 -c "
m=int('$mask',16); sys=__import__('sys'); sys.exit(0 if (m>>$bit)&1 else 1)
" 2>/dev/null; then
      echo "WARN: 0x$(printf '%x' "$WANT") may not be in the supported set (mask $mask)" >&2
    fi
  fi
fi

echo "== unbind $BDF from $DRV =="
if [ -e "$DEV/driver" ]; then
  cur=$(basename "$(readlink -f "$DEV/driver")")
  [ "$cur" = "$DRV" ] || die "device is bound to '$cur', expected '$DRV' - refusing to guess"
  echo "$BDF" > "/sys/bus/pci/drivers/$DRV/unbind" || die "unbind failed"
  echo "   unbound"
else
  echo "   (already unbound)"
fi

restore_driver() {
  echo "== rebind to $DRV =="
  if ! echo "$BDF" > "/sys/bus/pci/drivers/$DRV/bind" 2>/dev/null; then
    echo "STOP: rebind FAILED - the card is now driverless. Run:" >&2
    echo "      echo $BDF > /sys/bus/pci/drivers/$DRV/bind" >&2
    echo "      (or: echo $BDF > /sys/bus/pci/drivers_probe)" >&2
    return 1
  fi
  echo "   rebound"
}
trap restore_driver EXIT

echo "== set BAR1 size to $WANT bytes =="
printf '%d\n' "$WANT" > "$DEV/resource1_resize" || die "could not write resource1_resize"
echo "   wrote $WANT"

echo "== after =="
show
echo
echo "Done. Re-check with: lspci -vv -s ${BDF#0000:} | grep -A2 'Resizable BAR'"
