#!/usr/bin/env bash
# Apply / check / revert the current Cadence close/freeze patches.
# See docs/handoff.md for the full context.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 {apply|check|revert}" >&2
  exit 1
}

case "${1:-apply}" in
  apply)
    echo "== applying close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py
    echo "== applying launch-delay patches =="
    python3 scripts/patch-cadence-qprocess-timeout.py
    ;;
  check)
    echo "== close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py --check
    echo "== launch-delay patches =="
    python3 scripts/patch-cadence-qprocess-timeout.py --check
    ;;
  revert)
    echo "== reverting close/freeze patches =="
    python3 scripts/patch-libmanager-close-exit.py --revert
    echo "== reverting launch-delay patches =="
    python3 scripts/patch-cadence-qprocess-timeout.py --revert
    ;;
  *)
    usage
    ;;
esac
