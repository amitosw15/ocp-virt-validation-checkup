#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
RESULTS_DIR="$tmp/dry" DRY_RUN=true STORAGE_CLASS=test bash -c 'source "$1/scripts/csi/run.sh"' _ "$root"
grep -q 'skipped message="DRY_RUN=true"' "$tmp/dry/csi/junit.results.xml"
mkdir -p "$tmp/assets" "$tmp/runtime" "$tmp/plan/generation" "$tmp/thresholds/generation" "$tmp/missing"
printf 'catalog\n' > "$tmp/assets/catalog.json"
printf 'bundled plan\n' > "$tmp/assets/checkup-csi-smoke.yaml"
printf 'bundled thresholds\n' > "$tmp/assets/thresholds.json"
printf 'custom plan\n' > "$tmp/plan/generation/plan.yaml"
printf 'custom thresholds\n' > "$tmp/thresholds/generation/thresholds.json"
ln -s generation "$tmp/plan/..data"
ln -s generation "$tmp/thresholds/..data"
cat > "$tmp/harness" <<'EOF'
#!/bin/bash
echo "$*" >> "$CALLS"
case "$1" in
  version) echo test-version ;;
  validate) [ "${FAIL_VALIDATE:-false}" != true ] ;;
  run) mkdir -p "$RESULTS_DIR/csi/harness"; echo '<testsuite/>' > "$RESULTS_DIR/csi/harness/report.junit.flat.xml" ;;
esac
EOF
chmod +x "$tmp/harness"
export CALLS="$tmp/calls" HARNESS_BIN="$tmp/harness" HARNESS_CSI_ASSETS="$tmp/assets"
export VIRTBENCH_RUNTIME_SOURCE="$tmp/runtime" DRY_RUN=false STORAGE_CLASS=test
run_case() {
  local name="$1" plan="$2" thresholds="$3"
  export RESULTS_DIR="$tmp/$name" VIRTBENCH_RUNTIME_COPY="$tmp/runtime-$name"
  export CSI_PLAN_CONFIG_DIR="$plan" CSI_THRESHOLDS_CONFIG_DIR="$thresholds"
  export CSI_PLAN_CONFIG_MAP_NAME=custom-plan CSI_THRESHOLDS_CONFIG_MAP_NAME=custom-thresholds
  : > "$CALLS"
  bash -c 'source "$1/scripts/csi/run.sh"' _ "$root"
}
for pair in bundled plan thresholds both; do
  plan=; thresholds=
  [[ "$pair" == plan || "$pair" == both ]] && plan="$tmp/plan"
  [[ "$pair" == thresholds || "$pair" == both ]] && thresholds="$tmp/thresholds"
  run_case "$pair" "$plan" "$thresholds"
  test "$(cat "$RESULTS_DIR/csi/.exit_code")" = 0
  expected_plan=bundled; expected_thresholds=bundled
  [[ -n "$plan" ]] && expected_plan=configmap
  [[ -n "$thresholds" ]] && expected_thresholds=configmap
  jq -e --arg p "$expected_plan" --arg t "$expected_thresholds" '.plan_source == $p and .thresholds_source == $t' "$RESULTS_DIR/csi/configuration.json" >/dev/null
  grep -q '^run ' "$CALLS"
done
run_case missing-plan "$tmp/missing" ''
test "$(cat "$RESULTS_DIR/csi/.exit_code")" != 0
grep -q 'custom-plan must contain a nonempty plan.yaml' "$RESULTS_DIR/csi/csi-log.txt"
grep -q 'custom-plan must contain a nonempty plan.yaml' "$RESULTS_DIR/csi/junit.results.xml"
! grep -q '^run ' "$CALLS"
: > "$tmp/thresholds/generation/thresholds.json"
run_case empty-thresholds '' "$tmp/thresholds"
test "$(cat "$RESULTS_DIR/csi/.exit_code")" != 0
grep -q 'custom-thresholds must contain a nonempty thresholds.json' "$RESULTS_DIR/csi/csi-log.txt"
grep -q '<error ' "$RESULTS_DIR/csi/junit.results.xml"
export FAIL_VALIDATE=true
run_case invalid '' ''
test "$(cat "$RESULTS_DIR/csi/.exit_code")" != 0
! grep -q '^preflight\|^run ' "$CALLS"
grep -q '<error ' "$RESULTS_DIR/csi/junit.results.xml"

export FAIL_VALIDATE=false TEST_FOCUS='EX-001|EX-003' TEST_SKIPS='EX-003'
run_case selection '' ''
test "$(cat "$RESULTS_DIR/csi/.exit_code")" = 0
grep -q '^preflight .*--focus EX-001 --focus EX-003 --skip EX-003$' "$CALLS"
grep -q '^run .*--focus EX-001 --focus EX-003 --skip EX-003$' "$CALLS"

export TEST_FOCUS='' TEST_SKIPS='EX-001|EX-003'
run_case skips-only '' ''
grep -q '^preflight .*--skip EX-001 --skip EX-003$' "$CALLS"
grep -q '^run .*--skip EX-001 --skip EX-003$' "$CALLS"
! grep -q -- '--focus' "$CALLS"

export TEST_FOCUS='' TEST_SKIPS=''
run_case no-selection '' ''
! grep -q -- '--focus\|--skip' "$CALLS"
