#!/bin/sh
# /tools/cadence/bin/virtuoso — user wrapper that sets up the Cadence runtime
# env before exec'ing the 64-bit virtuoso binary. Install this at
# /tools/cadence/bin/virtuoso (the cadence-env PATH puts /tools/cadence/bin
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
# And on EXIT: kill the daemons virtuoso left behind — but only when this is
# the LAST session in the VM. The VM hosts multiple concurrent cadence-env
# sessions now, and the daemons (dashboard session lock, MPS servers) are
# shared per CDSBASE, so an exiting session must not reap them out from
# under the others. /bin/cadence-env-cleanup (from cadence-env.nix) does the
# reap with a "no more than MAX tcsh sessions" guard; this wrapper runs
# before its own parent tcsh exits, so MAX=1 means "just us left".
IC="/tools/cadence/IC251"
export LD_LIBRARY_PATH="$IC/share/oa/lib/lnx86/opt:$IC/tools.lnx86/lib/64bit:$IC/tools.lnx86/lib:$IC/tools.lnx86/sev/lib/64bit:$IC/tools.lnx86/hdf5/lib/64bit:$IC/tools.lnx86/lz4/lib/64bit:$IC/tools.lnx86/python/64bit/lib:$IC/tools.lnx86/TPtools/grpc/lib64:$IC/tools.lnx86/TPtools/boost/lib/64bit:$IC/tools.lnx86/extraction/lib/64bit:$IC/tools.lnx86/leveldb/lib/64bit:$IC/tools.lnx86/Qt/v5/64bit/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$IC/bin:$IC/tools/bin/64bit:$IC/tools/bin:$IC/tools/dfII/bin:$PATH"
cd "$HOME/work_gpdk045" || exit 1
"$IC/tools.lnx86/dfII/bin/64bit/virtuoso" "$@"
rc=$?
# virtuoso spawns detached daemons (`dashboard -runAsDaemon`, the MPS
# cdsNameServer/cdsMsgServer/cdsServIpc, clsbd, oaFSLockD, …) that under FEX are
# not reaped on exit. `dashboard` in particular keeps the session lock and
# blocks the next virtuoso launch. Reap them by name, then any remaining
# orphaned (reparented-to-PID-1) processes — but only when this is the last
# session (see the header comment).
/bin/cadence-env-cleanup 1 2>/dev/null
exit $rc
