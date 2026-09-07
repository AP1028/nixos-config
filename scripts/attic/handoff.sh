#!/usr/bin/env bash
# Apply / check / revert the current Cadence close/freeze patches.
# See docs/cadence-freeze.md for the full context.
set -euo pipefail
cd "$(dirname "$0")/.."

# The launch-delay (qprocess timeout) patch only makes sense under FEX on the
# macbook (aarch64): it shortens a 30s retry loop that FEX's emulation delays
# turn into 5-minute launches. On native x86_64 (asusg16) it must NOT be
# applied — the retry loop is legitimate there.
ARCH="$(uname -m)"

qprocess() {
  if [[ "$ARCH" == aarch64 ]]; then
    python3 scripts/patch-cadence-qprocess-timeout.py "${1:-}"
  else
    echo "== launch-delay patches: SKIPPED on $ARCH (FEX/macbook only) =="
  fi
}

usage() {
  echo "usage: $0 {apply|check|revert}" >&2
  exit 1
}

case "${1:-apply}" in
  apply)
    echo "== applying close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py
    echo "== applying launch-delay patches =="
    qprocess
    ;;
  check)
    echo "== close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py --check
    echo "== launch-delay patches =="
    qprocess --check
    ;;
  revert)
    echo "== reverting close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py --revert
    echo "== reverting launch-delay patches =="
    qprocess --revert
    ;;
  *)
    usage
    ;;
esac
