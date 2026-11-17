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

  HARNESS_BIN="${HARNESS_BIN:-/harness-assets/bin/harness}"
  HARNESS_CSI_ASSETS="${HARNESS_CSI_ASSETS:-/harness-assets/csi}"
  export HOME="${CSI_RESULTS_DIR}/home"
  mkdir -p "${HOME}/.config" "${HOME}/.local/share/containers"
  export PATH="/harness-assets/bin:/opt/virtbench-venv/bin:${PATH}"
  HARNESS_EXIT=0
  CSI_PLAN="${HARNESS_CSI_ASSETS}/checkup-csi-smoke.yaml"
  CSI_THRESHOLDS="${HARNESS_CSI_ASSETS}/thresholds.json"
  if [ -n "${CSI_PLAN_CONFIG_DIR:-}" ]; then CSI_PLAN="${CSI_RESULTS_DIR}/inputs/plan.yaml"; fi
  if [ -n "${CSI_THRESHOLDS_CONFIG_DIR:-}" ]; then CSI_THRESHOLDS="${CSI_RESULTS_DIR}/inputs/thresholds.json"; fi
  echo "CSI Harness suite started" | tee "${CSI_RESULTS_DIR}/csi-log.txt"
  set +e
  set -o pipefail
  (
    if [ -n "${CSI_PLAN_CONFIG_DIR:-}${CSI_THRESHOLDS_CONFIG_DIR:-}" ]; then
      mkdir "${CSI_RESULTS_DIR}/inputs" || { echo "CSI input snapshot directory already exists"; exit 1; }
    fi
    snapshot_input() {
      local config_dir="$1" key="$2" destination="$3" map_name="$4" generation attempt
      for attempt in 1 2 3; do
        generation=$(readlink -f "${config_dir}/..data") || continue
        if [ -s "${generation}/${key}" ] && cp "${generation}/${key}" "${destination}.tmp" && mv "${destination}.tmp" "${destination}"; then
          return 0
        fi
      done
      echo "CSI input error: ConfigMap ${map_name} must contain a nonempty ${key}" | tee "${CSI_RESULTS_DIR}/input-error.txt" >&2
      return 1
    }
    plan_source=bundled
    thresholds_source=bundled
    if [ -n "${CSI_PLAN_CONFIG_DIR:-}" ]; then
      snapshot_input "${CSI_PLAN_CONFIG_DIR}" plan.yaml "${CSI_PLAN}" "${CSI_PLAN_CONFIG_MAP_NAME:-unknown}" || exit 1
      plan_source=configmap
    fi
    if [ -n "${CSI_THRESHOLDS_CONFIG_DIR:-}" ]; then
      snapshot_input "${CSI_THRESHOLDS_CONFIG_DIR}" thresholds.json "${CSI_THRESHOLDS}" "${CSI_THRESHOLDS_CONFIG_MAP_NAME:-unknown}" || exit 1
      thresholds_source=configmap
    fi
    catalog_hash=$(sha256sum "${HARNESS_CSI_ASSETS}/catalog.json" | cut -d " " -f 1) || exit 1
    plan_hash=$(sha256sum "${CSI_PLAN}" | cut -d " " -f 1) || exit 1
    thresholds_hash=$(sha256sum "${CSI_THRESHOLDS}" | cut -d " " -f 1) || exit 1
    version=$("${HARNESS_BIN}" version 2>&1) || exit 1
    jq -n --arg plan_source "${plan_source}" --arg thresholds_source "${thresholds_source}" --arg plan_configmap "${CSI_PLAN_CONFIG_MAP_NAME:-}" --arg thresholds_configmap "${CSI_THRESHOLDS_CONFIG_MAP_NAME:-}" --arg catalog "${catalog_hash}" --arg plan "${plan_hash}" --arg thresholds "${thresholds_hash}" --arg version "${version}" '{plan_source:$plan_source, thresholds_source:$thresholds_source, plan_configmap:$plan_configmap, thresholds_configmap:$thresholds_configmap, catalog_sha256:$catalog, plan_sha256:$plan, thresholds_sha256:$thresholds, harness_version:$version}' > "${CSI_RESULTS_DIR}/configuration.json" || exit 1
    echo "CSI input plan_source=${plan_source} thresholds_source=${thresholds_source} catalog_sha256=${catalog_hash} plan_sha256=${plan_hash} thresholds_sha256=${thresholds_hash}"
    "${HARNESS_BIN}" validate --catalog "${HARNESS_CSI_ASSETS}/catalog.json" --thresholds "${CSI_THRESHOLDS}" || exit $?
    export LD_LIBRARY_PATH="/opt/virtbench-python-libs${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    cp -R "${VIRTBENCH_RUNTIME_SOURCE:-/opt/virtbench-runtime}" "${VIRTBENCH_RUNTIME_COPY:-/tmp/virtbench-runtime}" || exit 1
    chmod -R u+rwX "${VIRTBENCH_RUNTIME_COPY:-/tmp/virtbench-runtime}" || exit 1
    export VIRTBENCH_REPO="${VIRTBENCH_RUNTIME_COPY:-/tmp/virtbench-runtime}"
    "${HARNESS_BIN}" preflight \
      --catalog "${HARNESS_CSI_ASSETS}/catalog.json" \
      --plan "${CSI_PLAN}" \
      --backends "${CSI_BACKENDS_FILE}" \
      --backend checkup-storage \
    && "${HARNESS_BIN}" run \
      --catalog "${HARNESS_CSI_ASSETS}/catalog.json" \
      --thresholds "${CSI_THRESHOLDS}" \
      --plan "${CSI_PLAN}" \
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
    error_message="Harness exited ${HARNESS_EXIT} before producing a report; see csi-log.txt"
    if [ -s "${CSI_RESULTS_DIR}/input-error.txt" ]; then error_message=$(cat "${CSI_RESULTS_DIR}/input-error.txt"); fi
    error_message=$(printf "%s" "${error_message}" | sed -e "s/\&/\&amp;/g" -e "s/</\&lt;/g" -e "s/>/\&gt;/g" -e "s/\"/\&quot;/g" -e "s/'/\&apos;/g")
    cat > "${CSI_RESULTS_DIR}/junit.results.xml" <<EOF
<testsuites><testsuite name="csi" tests="1" errors="1"><testcase classname="csi" name="Harness run"><error message="${error_message}"/></testcase></testsuite></testsuites>
EOF
  fi
  echo "${HARNESS_EXIT}" > "${CSI_RESULTS_DIR}/.exit_code"
  fi
