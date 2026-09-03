#!/usr/bin/env bash
# Single-shot capture of kwin + Xwayland backtraces, after a delay.
#
# The DE-freeze-on-libManager-close bug (docs/cadence-fex.md "UNRESOLVED") is a
# Heisenbug: any CONTINUOUS observation (polling / periodic gdb) makes the close
# minimize instead of freeze. The only method that reproduces it is a single
# gdb attach AFTER a quiet delay. So: arm this (it sleeps DELAY seconds with no
# observation), close the libManager window during that window, and it attaches
# gdb once to kwin and Xwayland and dumps both stacks.
#
# Run as root (ptrace_scope=1 blocks non-root attach to kwin/Xwayland):
#   sudo-env -c 'setsid -f bash scripts/capture-kwin-xwayland.sh 10'
# Output: ~/.cadence/freeze_dump.log
DELAY="${1:-10}"
sleep "$DELAY"
KPID=$(pgrep -f "kwin_wayland --wayland-fd" | head -1)
XPID=$(pgrep -x Xwayland | head -1)
{
  echo "=== $(date) ==="
  echo "--- kwin (pid $KPID) ---"
  gdb -q -batch -p "$KPID" -ex "set pagination off" -ex "bt" -ex "thread apply all bt" 2>&1
  echo "--- Xwayland (pid $XPID) ---"
  gdb -q -batch -p "$XPID" -ex "set pagination off" -ex "bt" -ex "thread apply all bt" 2>&1
} > "${HOME}/.cadence/freeze_dump.log" 2>&1
