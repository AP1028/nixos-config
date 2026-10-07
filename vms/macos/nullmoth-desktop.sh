#!/bin/bash
# Bring the NullMoth desktop up after a boot.  Installed to the guest as
# /Library/NullMoth/nullmoth-desktop.sh by vms/macos/com.nullmoth.desktop.plist.
#
# WHY THIS EXISTS
# The driver ships its display and Metal paths gated OFF on purpose, and every
# gate is a runtime-only `debug.*` sysctl -- there is no config file that makes
# them persist. On top of that, WindowServer starts long before the driver is
# ready (the driver needs ~100 s), so even a permissive allow-list does not help
# the first WindowServer of a boot. Something has to re-apply the gates after
# each start, once the driver is actually up. This is that something.
#
# It is idempotent: safe to re-run by hand at any time.

set -u
LOG=/var/log/nullmoth-desktop.log
ALLOW=/Library/GPUBundles/nvmtl-allow.txt
exec >>"$LOG" 2>&1
echo "=== $(date) starting ==="

drv_up() { ioreg -l -w0 2>/dev/null | grep -q '"nvrm-autogo" = "up"'; }

# 0. Safety check. WindowServer must NOT be allowed to use this driver's Metal:
#    it switches to Metal compositing and the desktop then stops updating, while
#    the cursor keeps moving (the cursor is NVRMFB's hardware plane, not
#    WindowServer's). nvmtl_allowed() in plugin/NVMTLDevice.m stops at the FIRST
#    matching line, so the deny MUST precede the "*" line or it is dead code --
#    which is exactly how the shipped file is written ("*" then "!WindowServer",
#    making that line unreachable).
first_rule=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null | head -1 | tr -d '[:space:]')
if [ "$first_rule" != "-WindowServer" ]; then
    echo "WARNING: $ALLOW does not start with '-WindowServer' (first rule: '${first_rule:-none}')."
    echo "         Arming Metal in this state gives WindowServer the Metal path and the"
    echo "         desktop will freeze with the cursor still moving. Not arming Metal."
    ARM_METAL=0
else
    ARM_METAL=1
fi

# 1. Wait for the driver, not for "boot finished" -- the sysctls are silently
#    ignored before this point and the log then reads
#    "AGDC: no PCI device or no framebuffer yet".
for _ in $(seq 1 150); do drv_up && break; sleep 4; done
if ! drv_up; then
    echo "driver never reached nvrm-autogo=up; leaving the display alone"
    exit 1
fi
echo "driver is up: $(ioreg -l -w0 | grep -o '"nvrm-bars" = "[^"]*"' | head -1)"

if [ "$ARM_METAL" = 1 ]; then
    # 2. Arm Metal for APPLICATIONS (WindowServer is denied in the allow-list).
    sysctl -w debug.nvaccelfb=1
else
    sysctl -w debug.nvaccelfb=0
fi

# 3. Arm the AGDC display-policy shim so the framebuffer becomes mappable.
sysctl -w debug.nvrmfb_agdc=1

# 4. Restart WindowServer. This is what actually creates the IODisplay; it is
#    not optional, because WindowServer starts before the driver exists.
if pgrep -x WindowServer >/dev/null; then
    launchctl kickstart -k system/com.apple.WindowServer
    sleep 8
fi

echo "WindowServer pid $(pgrep -x WindowServer | head -1); IODisplay $(ioreg -rc IODisplay -w0 2>/dev/null | grep -c -- '+-o '); metal armed $ARM_METAL"
echo "=== done ==="
