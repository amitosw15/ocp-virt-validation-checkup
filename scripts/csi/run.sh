#!/bin/bash

  CSI_RESULTS_DIR="${RESULTS_DIR}/csi"
  CSI_REPORT_DIR="${CSI_RESULTS_DIR}/harness"
  CSI_BACKENDS_FILE="${CSI_RESULTS_DIR}/backends.yaml"
  mkdir -p "${CSI_REPORT_DIR}"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "CSI Harness suite skipped (DRY_RUN=true)" | tee "${CSI_RESULTS_DIR}/csi-log.txt"
    cat > "${CSI_RESULTS_DIR}/junit.results.xml" <<EOF
<testsuite name="csi" tests="1" skipped="1"><testcase classname="csi" name="Harness run"><skipped message="DRY_RUN=true"/></testcase></testsuite>
EOF
    echo "0" > "${CSI_RESULTS_DIR}/.exit_code"
  else
  cat > "${CSI_BACKENDS_FILE}" <<EOF
schema_version: "1"
backends:
  - name: checkup-storage
    storage_class: ${STORAGE_CLASS}
EOF

  HARNESS_BIN="/harness-assets/bin/harness"
  HARNESS_CSI_ASSETS="/harness-assets/csi"
  export HOME="${CSI_RESULTS_DIR}/home"
  mkdir -p "${HOME}/.config" "${HOME}/.local/share/containers"
  export PATH="/harness-assets/bin:/opt/virtbench-venv/bin:${PATH}"
  HARNESS_EXIT=0
  echo "CSI Harness suite started" | tee "${CSI_RESULTS_DIR}/csi-log.txt"
  set +e
  set -o pipefail
  (
    export LD_LIBRARY_PATH="/opt/virtbench-python-libs${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    cp -R /opt/virtbench-runtime /tmp/virtbench-runtime
    chmod -R u+rwX /tmp/virtbench-runtime
    export VIRTBENCH_REPO="/tmp/virtbench-runtime"
    "${HARNESS_BIN}" preflight \
      --catalog "${HARNESS_CSI_ASSETS}/catalog.json" \
      --plan "${HARNESS_CSI_ASSETS}/checkup-csi-smoke.yaml" \
      --backends "${CSI_BACKENDS_FILE}" \
      --backend checkup-storage \
    && "${HARNESS_BIN}" run \
      --catalog "${HARNESS_CSI_ASSETS}/catalog.json" \
      --thresholds "${HARNESS_CSI_ASSETS}/thresholds.json" \
      --plan "${HARNESS_CSI_ASSETS}/checkup-csi-smoke.yaml" \
      --backends "${CSI_BACKENDS_FILE}" \
      --backend checkup-storage \
      --no-attestations \
      --output "${CSI_REPORT_DIR}"
  ) 2>&1 | tee -a "${CSI_RESULTS_DIR}/csi-log.txt"
  HARNESS_EXIT=${PIPESTATUS[0]}
  set +o pipefail
  set -e
  echo "CSI Harness suite finished exit=${HARNESS_EXIT}" | tee -a "${CSI_RESULTS_DIR}/csi-log.txt"
  if [ -f "${CSI_REPORT_DIR}/report.junit.flat.xml" ]; then
    cp "${CSI_REPORT_DIR}/report.junit.flat.xml" "${CSI_RESULTS_DIR}/junit.results.xml"
  else
    if [ "${HARNESS_EXIT}" -eq 0 ]; then HARNESS_EXIT=1; fi
    cat > "${CSI_RESULTS_DIR}/junit.results.xml" <<EOF
<testsuites><testsuite name="csi" tests="1" errors="1"><testcase classname="csi" name="Harness run"><error message="Harness exited ${HARNESS_EXIT} before producing a report"/></testcase></testsuite></testsuites>
EOF
  fi
  echo "${HARNESS_EXIT}" > "${CSI_RESULTS_DIR}/.exit_code"
  fi
