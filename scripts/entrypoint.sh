#!/bin/bash

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/funcs.sh"
TEST_KUBEVIRT_SCRIPT="${SCRIPT_DIR}/kubevirt/test-kubevirt.sh"

export GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE:-validation-os-images}"
export GOLDEN_IMAGE_NAME="${GOLDEN_IMAGE_NAME:-win2k22}"

create_kubeconfig

# Add owner reference to PVC so it gets cleaned up when the job is deleted
add_pvc_owner_reference() {
  local namespace="${POD_NAMESPACE:-ocp-virt-validation}"
  local pod_name="${POD_NAME}"

  # Determine PVC name: derive from CONFIGMAP_NAME by removing -results suffix, or use default
  local pvc_name
  if [ -n "${CONFIGMAP_NAME}" ]; then
    # Remove -results suffix if present (for UI)
    pvc_name="${CONFIGMAP_NAME%-results}"
  else
    pvc_name="ocp-virt-validation-pvc-${TIMESTAMP}"
  fi

  if [ -z "${pod_name}" ]; then
    echo "Warning: POD_NAME not set, skipping PVC owner reference"
    return
  fi

  echo "Adding owner reference to PVC ${pvc_name}..."

  # Get job name and UID from the pod's owner reference
  local job_info=$(oc get pod "${pod_name}" -n "${namespace}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")]}' 2>/dev/null)

  if [ -z "${job_info}" ]; then
    echo "Warning: Could not find Job owner for pod ${pod_name}, skipping PVC owner reference"
    return
  fi

  local job_name=$(echo "${job_info}" | jq -r '.name')
  local job_uid=$(echo "${job_info}" | jq -r '.uid')

  if [ -z "${job_name}" ] || [ -z "${job_uid}" ] || [ "${job_name}" == "null" ] || [ "${job_uid}" == "null" ]; then
    echo "Warning: Could not extract job name or UID from pod owner reference, skipping PVC owner reference"
    return
  fi

  echo "Found owner Job: ${job_name} (UID: ${job_uid})"

  # Patch PVC with owner reference
  if oc patch pvc "${pvc_name}" -n "${namespace}" --type=json -p "[{\"op\":\"add\",\"path\":\"/metadata/ownerReferences\",\"value\":[{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"name\":\"${job_name}\",\"uid\":\"${job_uid}\",\"controller\":true,\"blockOwnerDeletion\":true}]}]" 2>/dev/null; then
    echo "Successfully added owner reference to PVC ${pvc_name}"
  else
    echo "Warning: Failed to add owner reference to PVC ${pvc_name}"
  fi
}

# Add owner reference to PVC if TIMESTAMP is set
if [ -n "${TIMESTAMP}" ]; then
  add_pvc_owner_reference
fi

# Check if we should only create results resources and exit
if [ "${CREATE_RESULTS_RESOURCES}" == "true" ]; then
  if [ -z "${TIMESTAMP}" ]; then
    echo "Error: CREATE_RESULTS_RESOURCES is set to 'true' but TIMESTAMP is not provided."
    exit 1
  fi
  
  echo "Creating results resources for TIMESTAMP=${TIMESTAMP}..."
  GET_RESULTS_SCRIPT="${SCRIPT_DIR}/../manifests/fetch/get_results.sh"
  
  if [ ! -f "${GET_RESULTS_SCRIPT}" ]; then
    echo "Error: get_results.sh script not found at ${GET_RESULTS_SCRIPT}"
    exit 1
  fi
  
  # Export TIMESTAMP and POD_NAMESPACE for the script
  export TIMESTAMP
  export POD_NAMESPACE="${POD_NAMESPACE:-ocp-virt-validation}"
  
  # Run the script and apply its output
  echo "Running get_results.sh and applying resources..."
  bash "${GET_RESULTS_SCRIPT}" | oc apply -f -
  
  if [ $? -eq 0 ]; then
    echo "Results resources created successfully."
    
    # Wait a moment for the route to be fully created
    sleep 2
    
    # Extract the route URL
    ROUTE_HOST=$(oc get route pvcreader-${TIMESTAMP} -n ${POD_NAMESPACE} -o jsonpath='{.status.ingress[0].host}' 2>/dev/null)
    
    if [ -n "${ROUTE_HOST}" ]; then
      DETAILED_RESULT_URL="https://${ROUTE_HOST}"
      echo "Route URL: ${DETAILED_RESULT_URL}"
      
      # Update the ConfigMap with detailed_results_url and detailed_results_file
      CONFIGMAP_NAME="${CONFIGMAP_NAME:-ocp-virt-validation-${TIMESTAMP}}"
      if oc get configmap "${CONFIGMAP_NAME}" -n ${POD_NAMESPACE} &>/dev/null; then
        echo "Updating ConfigMap ${CONFIGMAP_NAME} with detailed results..."

        # Add detailed_results_url and detailed_results_file as separate keys
        oc patch configmap "${CONFIGMAP_NAME}" -n ${POD_NAMESPACE} --type=merge -p "{\"data\":{\"detailed_results_url\":\"${DETAILED_RESULT_URL}\",\"detailed_results_file\":\"test-results-${TIMESTAMP}.tar.gz\"}}"
        
        if [ $? -eq 0 ]; then
          echo "ConfigMap updated successfully with detailed results:"
          echo "  URL: ${DETAILED_RESULT_URL}"
          echo "  Filename: test-results-${TIMESTAMP}.tar.gz"
        else
          echo "Warning: Failed to update ConfigMap with detailed results"
        fi
      else
        echo "Warning: ConfigMap ${CONFIGMAP_NAME} not found, skipping detailed results update"
      fi
      
      echo "To view the results, visit: ${DETAILED_RESULT_URL}"
    else
      echo "Warning: Could not extract route URL"
      echo "To view the results, run:"
      echo "  oc get route pvcreader-${TIMESTAMP} -n ${POD_NAMESPACE} -o jsonpath='{.status.ingress[0].host}'"
    fi
    
    exit 0
  else
    echo "Error: Failed to create results resources."
    exit 1
  fi
fi

# Normal test execution flow continues below
DRY_RUN_FLAG=""
if [ "${DRY_RUN}" == "true" ]
then
  DRY_RUN_FLAG="--ginkgo.dry-run"
fi
export DRY_RUN_FLAG

mkdir -p ${RESULTS_DIR}
START_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${START_TIMESTAMP} > ${RESULTS_DIR}/startTimestamp

# Global variable to track currently running test script
CURRENT_TEST_PID=""

# Progress watcher PID (will be started later after storage config is set)
PROGRESS_WATCHER_PID=""

# Cleanup Windows golden image resources.
# Only clean up what the current run created.
# EULA gate: if this run didn't create the namespace, don't touch it.
# Label gate: if the namespace isn't tool-labeled, it belongs to the user (BYOI).
cleanup_windows_resources() {
    if [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
        return
    fi
    cleanup_golden_image_resources "${GOLDEN_IMAGE_NAMESPACE}"
}

# Function to cleanup progress watcher and forward signals
cleanup_and_forward_signal() {
    echo "Entrypoint received termination signal, cleaning up..."
    
    # Forward signal to currently running test script to trigger its trap
    if [[ -n "${CURRENT_TEST_PID}" ]] && kill -0 "${CURRENT_TEST_PID}" 2>/dev/null; then
        echo "Forwarding SIGTERM to test script (PID: ${CURRENT_TEST_PID})..."
        kill -TERM "${CURRENT_TEST_PID}" 2>/dev/null || true
        # Wait for the test script to cleanup gracefully
        echo "Waiting for test script to complete cleanup..."
        wait "${CURRENT_TEST_PID}" 2>/dev/null || true
        echo "Test script cleanup completed."
    fi
    
    # Cleanup progress watcher
    if [[ -n "${PROGRESS_WATCHER_PID}" ]] && kill -0 "${PROGRESS_WATCHER_PID}" 2>/dev/null; then
        echo "Stopping progress watcher (PID: ${PROGRESS_WATCHER_PID})..."
        kill "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
        wait "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
        echo "Progress watcher stopped."
    fi

    cleanup_windows_resources
    
    exit 1
}

# Set trap to cleanup and forward signals
trap cleanup_and_forward_signal INT TERM

ALLOWED_TEST_SUITES="compute|network|storage|ssp|tier2|csi"
if [[ ! "$TEST_SUITES" =~ ^($ALLOWED_TEST_SUITES)(,($ALLOWED_TEST_SUITES))*$ ]]; then
  echo "Invalid TEST_SUITES format: \"$TEST_SUITES\""
  echo "Allowed values: comma-separated list of [$ALLOWED_TEST_SUITES]"
  exit 1
fi


VALID_FILTER_REGEX='^([^|]+)(\|([^|]+))*$'
if [[ -n "${TEST_SKIPS}" && ! "${TEST_SKIPS}" =~ ${VALID_FILTER_REGEX} ]]; then
  echo "Invalid TEST_SKIPS format: \"${TEST_SKIPS}\""
  echo "Expected: pipe-separated list of test cases"
  exit 1
fi

if [[ -n "${TEST_FOCUS}" && ! "${TEST_FOCUS}" =~ ${VALID_FILTER_REGEX} ]]; then
  echo "Invalid TEST_FOCUS format: \"${TEST_FOCUS}\""
  echo "Expected: pipe-separated list of test cases"
  exit 1
fi

if [[ -n "${TEST_FOCUS}" && -n "${TEST_SKIPS}" ]]; then
  IFS='|' read -ra focus_entries <<< "${TEST_FOCUS}"
  IFS='|' read -ra skip_entries <<< "${TEST_SKIPS}"
  for f in "${focus_entries[@]}"; do
    for s in "${skip_entries[@]}"; do
      if [[ "${f}" == "${s}" ]]; then
        echo "WARNING: '${f}' appears in both TEST_FOCUS and TEST_SKIPS. TEST_FOCUS takes precedence; test will run."
      fi
    done
  done
fi

IFS=',' read -ra SUITES <<< "$TEST_SUITES"

suite_enabled() {
  local target="$1"
  for suite in "${SUITES[@]}"; do
    if [[ "$suite" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

if suite_enabled "csi" && { [ -n "${TEST_FOCUS}" ] || [ -n "${TEST_SKIPS}" ]; }; then
  echo "WARNING: TEST_FOCUS and TEST_SKIPS apply only to native Checkup suites; the csi Harness plan runs its full selection."
fi

HAS_NATIVE_SUITE=false
for suite in "${SUITES[@]}"; do
  if [[ "$suite" != "csi" ]]; then
    HAS_NATIVE_SUITE=true
    break
  fi
done

if [ "$HAS_NATIVE_SUITE" = true ]; then
  get_virtctl
  REGISTRY_CONFIG=$(mktemp)
  oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\\.dockerconfigjson}' | base64 -d > "${REGISTRY_CONFIG}"
  export REGISTRY_CONFIG
  VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[0].image}')
  KUBEVIRT_TAG=$(oc image info -a ${REGISTRY_CONFIG} ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
  if [ -z "${KUBEVIRT_TAG}" ]; then
    CSV_VERSION=$(oc get csv -n openshift-cnv -o json | jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).spec.version')
    if [ -n "${CSV_VERSION}" ]; then
      KONFLUX_VERSION="v$(echo ${CSV_VERSION} | cut -d. -f1)-$(echo ${CSV_VERSION} | cut -d. -f2)"
      IMAGE_NAME_WITH_DIGEST=$(echo "${VIRT_OPERATOR_IMAGE}" | sed 's|.*/||')
      KONFLUX_IMAGE="quay.io/openshift-virtualization/konflux-builds/${KONFLUX_VERSION}/${IMAGE_NAME_WITH_DIGEST}"
      echo "Trying konflux-builds fallback: ${KONFLUX_IMAGE}"
      KUBEVIRT_TAG=$(oc image info -a ${REGISTRY_CONFIG} ${KONFLUX_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
    fi
  fi
  if [ -z "${KUBEVIRT_TAG}" ]; then
    export KUBEVIRT_RELEASE="v1.8.2"
    echo "WARNING: Could not auto-detect KubeVirt release tag. Using default: ${KUBEVIRT_RELEASE}"
  else
    export KUBEVIRT_RELEASE="v${KUBEVIRT_TAG%%-[0-9]*}"
  fi
fi

if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0]'.metadata.name)
fi

if [ -z "${STORAGE_CLASS}" ]; then
  echo "Error: No storage class specified with STORAGE_CLASS env var and a default storage class was not found in the cluster"
  exit 1
fi
export STORAGE_CLASS

# Find matching storage configuration file
STORAGE_CONFIG_FILE=""
if [ -n "${STORAGE_CLASS}" ]; then
  echo "Looking for storage configuration file matching storage class: ${STORAGE_CLASS}"
  
  # Search through all JSON files in the storage config directory
  for config_file in "${SCRIPT_DIR}/kubevirt/config/storage"/*.json; do
    if [ -f "$config_file" ]; then
      # Check if any value in the JSON file matches our storage class
      if jq -e --arg storage_class "${STORAGE_CLASS}" '. as $obj | [$obj[]] | any(. == $storage_class)' "$config_file" >/dev/null 2>&1; then
        # Extract just the filename (without path and extension)
        STORAGE_CONFIG_FILE=$(basename "$config_file" .json)
        echo "Found matching storage configuration: ${STORAGE_CONFIG_FILE}"
        break
      fi
    fi
  done
  
  if [ -z "${STORAGE_CONFIG_FILE}" ]; then
    echo "Warning: No storage configuration file found for storage class '${STORAGE_CLASS}'"
    echo "Available storage configurations:"
    {
      for config_file in "${SCRIPT_DIR}/kubevirt/config/storage"/*.json; do
        if [ -f "$config_file" ]; then
          # Extract the first value from the JSON file (all values are the same)
          storage_class_value=$(jq -r '. as $obj | [$obj[]] | .[0]' "$config_file" 2>/dev/null)
          echo "${storage_class_value}"
        fi
      done
    } | sort -u | sed 's/^/  /' || echo "  None found"
  fi
else
  echo "Warning: No storage class specified or detected"
fi

# Export the storage config file name for use in ginkgo
export STORAGE_CONFIG_FILE

# Handle custom storage capabilities if specified
if [ -n "${STORAGE_CAPABILITIES}" ]; then
  echo "Processing custom storage capabilities: ${STORAGE_CAPABILITIES}"
  
  # Define valid storage capabilities
  valid_capabilities=("storageClassRhel" "storageClassWindows" "storageRWXBlock" "storageRWXFileSystem" "storageRWOFileSystem" "storageRWOBlock" "storageClassCSI" "storageSnapshot" "onlineResize" "WFFC")
  
  # Validate STORAGE_CAPABILITIES format and content
  IFS=',' read -ra capabilities_array <<< "${STORAGE_CAPABILITIES}"
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    # Check if capability is valid
    valid=false
    for valid_cap in "${valid_capabilities[@]}"; do
      if [ "$capability" = "$valid_cap" ]; then
        valid=true
        break
      fi
    done
    
    if [ "$valid" = false ]; then
      echo "Error: Invalid storage capability '${capability}' in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
  done
  
  # Ensure we have a storage class for the custom configuration
  if [ -z "${STORAGE_CLASS}" ]; then
    echo "Error: STORAGE_CLASS must be set when using STORAGE_CAPABILITIES"
    exit 1
  fi
  
  # Create custom storage configuration file in writable results directory
  custom_config_file="${RESULTS_DIR}/custom-storage-config.json"
  echo "Creating custom storage configuration: ${custom_config_file}"
  
  # Build JSON object with specified capabilities
  json_content="{"
  first=true
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    if [ "$first" = true ]; then
      first=false
    else
      json_content="${json_content},"
    fi
    json_content="${json_content}\"${capability}\": \"${STORAGE_CLASS}\""
  done
  json_content="${json_content}}"
  
  # Write the custom configuration file
  echo "$json_content" | jq '.' > "$custom_config_file"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to create custom storage configuration file"
    exit 1
  fi
  
  # Use the custom configuration
  export KUBEVIRT_STORAGE_CONFIGURATION_FILE="$(basename "$custom_config_file")"
  export KUBEVIRT_STORAGE_CONFIG_IS_CUSTOM="true"
  echo "Custom storage configuration created and will be used: ${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
  echo "Configuration content:"
  cat "$custom_config_file"
  
else
  # Use existing logic for predefined storage configurations
  # Also export in a format similar to KUBEVIRT_TESTING_CONFIGURATION_FILE for consistency
  if [ -n "${STORAGE_CONFIG_FILE}" ]; then
    export KUBEVIRT_STORAGE_CONFIGURATION_FILE="${STORAGE_CONFIG_FILE}.json"
    export KUBEVIRT_STORAGE_CONFIG_IS_CUSTOM="false"
    echo "Storage configuration will use: ${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
  else
    # Clear the variable if no storage config file was found
    unset KUBEVIRT_STORAGE_CONFIGURATION_FILE
    unset KUBEVIRT_STORAGE_CONFIG_IS_CUSTOM
  fi
fi

# ======================
# Windows Golden Image Setup
# ======================
# Run the Windows setup script which handles both paths:
#   - BYOI: DataSource exists and is Ready → exits immediately
#   - Tool-created: ACCEPT_WINDOWS_EULA=true → runs pipeline
# Exit code contract with setup-golden-image.sh (must stay in sync):
#   0              = success or expected skip (BYOI ready, EULA not set)
#   EXIT_WINDOWS_SKIP = prerequisite missing (no internet, pipeline not installed) — skip Windows gracefully, other suites continue
#   anything else  = real failure (pipeline ran and failed, timeout, config error) — hard fail so CI detects it
readonly EXIT_WINDOWS_SKIP=2

WINDOWS_SETUP_SCRIPT="${SCRIPT_DIR}/windows/setup-golden-image.sh"
if [ "${HAS_NATIVE_SUITE}" = true ] && [ -f "${WINDOWS_SETUP_SCRIPT}" ]; then
  export STORAGE_CLASS
  export WIN_IMAGE_DOWNLOAD_URL
  export TEKTON_PIPELINE_VERSION
  export ACCEPT_WINDOWS_EULA
  WINDOWS_SETUP_EXIT=0
  bash "${WINDOWS_SETUP_SCRIPT}" || WINDOWS_SETUP_EXIT=$?
  case ${WINDOWS_SETUP_EXIT} in
    0)
      ;;
    "${EXIT_WINDOWS_SKIP}")
      echo "WARNING: Windows golden image setup skipped (missing prerequisite). Windows tests will be skipped."
      echo "All other test suites will continue normally."
      unset ACCEPT_WINDOWS_EULA
      ;;
    *)
      echo "ERROR: Windows golden image setup failed (exit ${WINDOWS_SETUP_EXIT}). Aborting validation."
      exit 1
      ;;
  esac
fi

# Start progress watcher in background AFTER storage config is set
echo "Starting progress watcher for multi-suite monitoring..."
progress_watcher --results-dir="${RESULTS_DIR}" &
PROGRESS_WATCHER_PID=$!
echo "Progress watcher started with PID: ${PROGRESS_WATCHER_PID}"

# =======
# compute
# =======
if suite_enabled "compute"; then
  echo "Running KubeVirt test suite..."
  SIG="compute" "${TEST_KUBEVIRT_SCRIPT}" &
  CURRENT_TEST_PID=$!
  wait ${CURRENT_TEST_PID}
  CURRENT_TEST_PID=""
  echo "KubeVirt test suite has finished."
else
  echo "KubeVirt test suite has been skipped."
fi


# =======
# Network
# =======
if suite_enabled "network"; then
  echo "Running Network test suite..."
  SIG="network" "${TEST_KUBEVIRT_SCRIPT}" &
  CURRENT_TEST_PID=$!
  wait ${CURRENT_TEST_PID}
  CURRENT_TEST_PID=""
  echo "Network test suite has finished."
else
  echo "Network test suite has been skipped."
fi


# =======
# Storage
# =======
if suite_enabled "storage"; then
  echo "Running Storage test suite..."
  SIG="storage" "${TEST_KUBEVIRT_SCRIPT}" &
  CURRENT_TEST_PID=$!
  wait ${CURRENT_TEST_PID}
  CURRENT_TEST_PID=""
  echo "Storage test suite has finished."
else
  echo "Storage test suite has been skipped."
fi


# ====
# SSP
# ====
if suite_enabled "ssp"; then
  echo "Running SSP test suite..."
  ${SCRIPT_DIR}/ssp/test-ssp.sh &
  CURRENT_TEST_PID=$!
  wait ${CURRENT_TEST_PID}
  CURRENT_TEST_PID=""
else
  echo "SSP test suite has been skipped."
fi


# =======
# Tier-2
# =======
if suite_enabled "tier2"; then
  echo "Running Tier-2 (openshift-virtualization-tests) test suite..."
  ${SCRIPT_DIR}/tier2/test-tier2.sh &
  CURRENT_TEST_PID=$!
  wait ${CURRENT_TEST_PID}
  CURRENT_TEST_PID=""
  echo "Tier-2 test suite has finished."
else
  echo "Tier-2 test suite has been skipped."
fi

if suite_enabled "csi"; then
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
else
  echo "CSI Harness suite has been skipped."
fi


COMPLETION_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${COMPLETION_TIMESTAMP} > ${RESULTS_DIR}/completionTimestamp

# Stop progress watcher before summarizing results
if [[ -n "${PROGRESS_WATCHER_PID}" ]] && kill -0 "${PROGRESS_WATCHER_PID}" 2>/dev/null; then
    echo "Stopping progress watcher (PID: ${PROGRESS_WATCHER_PID})..."
    kill "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
    wait "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
    echo "Progress watcher stopped."
fi

# Clean up .dry-run directory if it still exists (used by progress_watcher for test discovery)
if [ -d "${RESULTS_DIR}/.dry-run" ]; then
    echo "Cleaning up .dry-run directory..."
    rm -rf "${RESULTS_DIR}/.dry-run"
fi

# ================================
# Windows Golden Image Cleanup
# ================================
cleanup_windows_resources

# =========
# Summarize
# =========
PARSER_EXIT=0
junit_parser --results-dir=${RESULTS_DIR}  --start-timestamp=${START_TIMESTAMP} --completion-timestamp=${COMPLETION_TIMESTAMP} | tee ${RESULTS_DIR}/summary-log.txt || PARSER_EXIT=$?

# Archive test results into tar.gz (exclude .dry-run directory as a defensive measure)
tar -czf /tmp/test-results-${TIMESTAMP}.tar.gz -C ${RESULTS_DIR} --exclude='.dry-run' .
mv /tmp/test-results-${TIMESTAMP}.tar.gz ${RESULTS_DIR}/test-results-${TIMESTAMP}.tar.gz

if [ ${PARSER_EXIT} -ne 0 ]; then
  echo "Self Validation test run finished with errors (setup failure detected, no ConfigMap created)."
  exit 1
fi

echo "Self Validation test run is done."
