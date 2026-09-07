#!/usr/bin/env bash
# Single-shot capture of kwin + Xwayland + Cadence client backtraces, after a delay.
#
# The DE-freeze-on-Cadence-close bug (docs/cadence-freeze.md) is a Heisenbug: any
# CONTINUOUS observation (polling / periodic gdb) makes the close behave
# instead of freeze. The only reliable method is a single gdb attach AFTER a
# quiet delay. Arm this (it sleeps DELAY seconds with no observation), do the
# close/drag during that window, and it attaches gdb once to kwin, Xwayland
# and any running Cadence clients and dumps their stacks.
#
# Run as root (ptrace_scope=1 blocks non-root attach to kwin/Xwayland):
#   sudo-env -c 'setsid -f bash scripts/capture-kwin-xwayland.sh 15'
# Output: ~/.cadence/freeze_dump.log
DELAY="${1:-15}"
sleep "$DELAY"
KPID=$(pgrep -f "kwin_wayland --wayland-fd" | head -1)
XPID=$(pgrep -x Xwayland | head -1)
{
  echo "=== $(date) ==="
  echo "--- process states (D = uninterruptible, R = running/spinning) ---"
  ps -eo pid,stat,wchan:32,pcpu,comm | grep -E 'Xwayland|kwin|virtuoso|libManager|cdsLibEditor' | grep -v grep
  dump() {
    local name="$1" pid="$2"
    shift 2
    if [ -z "$pid" ]; then
      echo "--- $name: not running ---"
      return
    fi
    echo "--- $name (pid $pid) ---"
    timeout 180 gdb -q -batch -p "$pid" -ex "set pagination off" "$@" 2>&1
  }
  dump kwin "$KPID" -ex "bt" -ex "thread apply all bt"
  dump Xwayland "$XPID" -ex "bt" -ex "thread apply all bt"
  dump virtuoso "$(pgrep -x virtuoso | head -1)" -ex "info threads" -ex "bt"
  dump libManager "$(pgrep -x libManager | head -1)" -ex "info threads" -ex "bt"
} > "/home/tianyixia/.cadence/freeze_dump.log" 2>&1
