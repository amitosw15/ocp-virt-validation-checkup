#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export OCP_VIRT_VALIDATION_IMAGE=example/checkup TEST_SUITES=csi
CSI_PLAN_CONFIG_MAP=my-plan CSI_THRESHOLDS_CONFIG_MAP=my-thresholds bash "$root/manifests/run/generate.sh" > "$tmp/both"
grep -q 'name: check-csi-config-capability' "$tmp/both"
grep -q 'name: my-plan' "$tmp/both"
grep -q 'name: my-thresholds' "$tmp/both"
test "$(grep -c 'optional: true' "$tmp/both")" -eq 2
grep -q 'CSI_PLAN_CONFIG_DIR' "$tmp/both"
grep -q 'CSI_THRESHOLDS_CONFIG_DIR' "$tmp/both"
CSI_PLAN_CONFIG_MAP=my-plan bash "$root/manifests/run/generate.sh" > "$tmp/plan"
grep -q 'csi-plan-input' "$tmp/plan"
! grep -q 'csi-thresholds-input' "$tmp/plan"
CSI_THRESHOLDS_CONFIG_MAP=my-thresholds bash "$root/manifests/run/generate.sh" > "$tmp/thresholds"
grep -q 'csi-thresholds-input' "$tmp/thresholds"
! grep -q 'csi-plan-input' "$tmp/thresholds"
CSI_PLAN_CONFIG_MAP=my-plan DRY_RUN=true bash "$root/manifests/run/generate.sh" > "$tmp/dry"
! grep -q 'csi-plan-input' "$tmp/dry"
bash "$root/manifests/run/generate.sh" > "$tmp/bundled"
! grep -q 'csi-plan-input\|csi-thresholds-input' "$tmp/bundled"
if CSI_PLAN_CONFIG_MAP=Invalid bash "$root/manifests/run/generate.sh" > /dev/null 2>&1; then exit 1; fi
if CSI_THRESHOLDS_CONFIG_MAP=my-config TEST_SUITES=storage bash "$root/manifests/run/generate.sh" > /dev/null 2>&1; then exit 1; fi
