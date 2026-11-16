#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
RESULTS_DIR="$tmp" DRY_RUN=true STORAGE_CLASS=test bash -c 'source "$1/scripts/csi/run.sh"' _ "$root"
test "$(cat "$tmp/csi/.exit_code")" = 0
grep -q 'skipped message="DRY_RUN=true"' "$tmp/csi/junit.results.xml"
grep -q 'CSI Harness suite skipped (DRY_RUN=true)' "$tmp/csi/csi-log.txt"
