#!/bin/bash
# ############################################################################
# DEPRECATED -- kept only for the record. DO NOT INSTALL THIS.
#
# Superseded by the `nvrmsettle=15000` boot-arg. The driver now arms the display
# and the Metal plugin itself during boot (the 40 s IORegistry boot-hold finally
# outlives the bring-up), so no runtime steps are needed at all.
#
# Worse, this script's WindowServer restart is now actively HARMFUL: since
# nvmtl-allow.txt lists WindowServer as "!WindowServer" (allowed when armed), and
# the driver self-arms at boot, a mid-session restart hands WindowServer a Metal
# compositing path it cannot sustain and the UI stops updating.
#
# It remains useful only as a manual recovery from the "changing resolution
# wedges the display" bug documented in DRIVER-INSTALL-NOTES.md -- but even there
# `launchctl kickstart -k system/com.apple.WindowServer` is the whole fix.
# ############################################################################
#
# Bring the NullMoth desktop up after a boot.  Installed to the guest as
# /Library/NullMoth/nullmoth-desktop.sh by vms/macos/com.nullmoth.desktop.plist.
#
# WHY THIS EXISTED
# The driver ships its display and Metal paths gated OFF, and every gate was a
# runtime-only `debug.*` sysctl with no config file behind it. WindowServer also
# started long before the driver was ready (the slow path is a 100 s bring-up), so
# even a permissive allow-list did not help the first WindowServer of a boot.
# Something had to re-apply the gates once the driver was up. This was that
# something -- before `nvrmsettle` removed the problem at its source.
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
# 0. Metal is deliberately NOT armed by default. Arming it
#    (`debug.nvaccelfb=1`) does two things that break the desktop:
#      * the accelerator publishes IOGLBundleName=AppleMetalOpenGLRenderer,
#        which redirects the GL renderer GLOBALLY, so denying WindowServer in
#        nvmtl-allow.txt is not enough to keep it off the GL-over-Metal path;
#      * WindowServer switches to Metal compositing.
#    Either way the UI stops updating -- the desktop freezes (or sits on the
#    boot screen) while the cursor keeps moving, because the cursor is NVRMFB's
#    hardware plane. And it cannot be undone at runtime: `sysctl -w
#    debug.nvaccelfb=0` does nothing (the driver says "a reboot takes it away
#    again"), so recovery always costs a reboot. So: off, unless asked.
#
#    Set NULLMOTH_ARM_METAL=1 (e.g. a second plist, or by hand) if you want
#    Metal at the cost of the desktop.
ARM_METAL="${NULLMOTH_ARM_METAL:-0}"

# Sanity: if you do opt in, the allow-list must deny WindowServer FIRST --
# nvmtl_allowed() stops at the first matching line.
if [ "$ARM_METAL" = 1 ]; then
    first_rule=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ "$first_rule" != "-WindowServer" ]; then
        echo "WARNING: $ALLOW does not start with '-WindowServer' (first rule: '${first_rule:-none}')."
        echo "         Not arming Metal; it would freeze the desktop."
        ARM_METAL=0
    fi
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

# 2. Arm Metal only if explicitly requested (see the note above).
if [ "$ARM_METAL" = 1 ]; then
    sysctl -w debug.nvaccelfb=1
else
    echo "Metal left off (debug.nvaccelfb=0); pass NULLMOTH_ARM_METAL=1 to opt in"
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
