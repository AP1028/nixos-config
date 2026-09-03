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
IC="$HOME/.cadence/IC251"
export LD_LIBRARY_PATH="$IC/share/oa/lib/lnx86/opt:$IC/tools.lnx86/lib/64bit:$IC/tools.lnx86/lib:$IC/tools.lnx86/sev/lib/64bit:$IC/tools.lnx86/hdf5/lib/64bit:$IC/tools.lnx86/lz4/lib/64bit:$IC/tools.lnx86/python/64bit/lib:$IC/tools.lnx86/TPtools/grpc/lib64:$IC/tools.lnx86/TPtools/boost/lib/64bit:$IC/tools.lnx86/extraction/lib/64bit:$IC/tools.lnx86/leveldb/lib/64bit:$IC/tools.lnx86/Qt/v5/64bit/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$IC/bin:$IC/tools/bin/64bit:$IC/tools/bin:$IC/tools/dfII/bin:$PATH"
cd ~/.cadence/work_gpdk045 || exit 1
exec "$IC/tools.lnx86/dfII/bin/64bit/virtuoso" "$@"
