#!/bin/sh
# ~/.cadence/bin/virtuoso — user wrapper that sets up the Cadence runtime env
# before exec'ing the 64-bit virtuoso binary. Install this at
# ~/.cadence/bin/virtuoso (the cadence-env guest PATH puts ~/.cadence/bin
# first, so this wrapper is what `cadence-env -c 'virtuoso'` actually runs).
#
# Two jobs:
#   1. LD_LIBRARY_PATH — the x86_64 Cadence/OA/Qt lib dirs, so the FEX guest's
#      ld-linux finds the install-tree libs.
#   2. PATH — put the install-tree bin dirs FIRST. cds_root resolves `virtuoso`
#      via $PATH and walks parent dirs for tools/bin/cds_root; if it finds this
#      wrapper (outside the install tree) it reports "can't determine
#      installation root". The re-order makes cds_root find the real binary.
#
# And on EXIT (not launch — cadence-env/muvm is single-instanced, so a second
# launch never reaches this wrapper): kill the daemons virtuoso left behind,
# so the guest VM shuts down and the next `cadence-env` can start.
IC="$HOME/.cadence/IC251"
export LD_LIBRARY_PATH="$IC/share/oa/lib/lnx86/opt:$IC/tools.lnx86/lib/64bit:$IC/tools.lnx86/lib:$IC/tools.lnx86/sev/lib/64bit:$IC/tools.lnx86/hdf5/lib/64bit:$IC/tools.lnx86/lz4/lib/64bit:$IC/tools.lnx86/python/64bit/lib:$IC/tools.lnx86/TPtools/grpc/lib64:$IC/tools.lnx86/TPtools/boost/lib/64bit:$IC/tools.lnx86/extraction/lib/64bit:$IC/tools.lnx86/leveldb/lib/64bit:$IC/tools.lnx86/Qt/v5/64bit/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$IC/bin:$IC/tools/bin/64bit:$IC/tools/bin:$IC/tools/dfII/bin:$PATH"
cd ~/.cadence/work_gpdk045 || exit 1
"$IC/tools.lnx86/dfII/bin/64bit/virtuoso" "$@"
rc=$?
# virtuoso spawns detached daemons (`dashboard -runAsDaemon`, the MPS
# cdsNameServer/cdsMsgServer/cdsServIpc, clsbd, oaFSLockD, …) that under FEX are
# not reaped on exit. `dashboard` in particular keeps the session lock and
# blocks the next launch. Kill them by name, then reap any remaining orphaned
# (reparented-to-PID-1) processes, so the guest VM shuts down cleanly.
for p in dashboard cdsNameServer cdsMsgServer cdsServIpc clsbd progressWidget cdsVncserver oaFSLockD perfUtilExtCtrl libManager libSelect; do
  pkill -9 -f "$p" 2>/dev/null
done
for d in /proc/[0-9]*; do
  pid=${d##*/}
  [ "$pid" = "$$" ] && continue
  ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
  [ "$ppid" = "1" ] && kill -9 "$pid" 2>/dev/null
done
exit $rc
