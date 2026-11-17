#!/bin/bash

# This script generates the manifests required to run the ocp-virt validation checkup


if [ -z "${OCP_VIRT_VALIDATION_IMAGE}" ]
then
  echo "Error: Please provide OCP_VIRT_VALIDATION_IMAGE environment variable. Get it by running:"
  echo 'CSV_NAME=$(oc get csv -n openshift-cnv -o json | jq -r '\''.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name'\'')'
  echo 'oc get csv -n openshift-cnv $CSV_NAME -o json | jq -r '\''.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image'\'
  exit 1
fi

DRY_RUN=${DRY_RUN:-"false"}
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

TEST_SUITES=${TEST_SUITES:-"compute,network,storage,ssp,tier2"}
FULL_SUITE=${FULL_SUITE:-"false"}
STORAGE_CLASS=${STORAGE_CLASS:-""}
STORAGE_CAPABILITIES=${STORAGE_CAPABILITIES:-""}
HARNESS_IMAGE=${HARNESS_IMAGE:-"quay.io/amitos/storage-cert-harness@sha256:640ed10d7b371b2459a1a6eaa729b4c740cefc0d1a0a0c67fca23129d33b0654"}
ACCEPT_WINDOWS_EULA=${ACCEPT_WINDOWS_EULA:-"false"}
WIN_IMAGE_DOWNLOAD_URL=${WIN_IMAGE_DOWNLOAD_URL:-""}
TEKTON_PIPELINE_VERSION=${TEKTON_PIPELINE_VERSION:-""}
PRIMARY_NETWORK_BINDING_PLUGIN=${PRIMARY_NETWORK_BINDING_PLUGIN:-""}

# Calculate storage size based on test suites (2Gi per suite, 10Gi for tier2)
IFS=',' read -ra TEST_SUITES_ARRAY <<< "${TEST_SUITES}"
TOTAL_STORAGE=0
for suite in "${TEST_SUITES_ARRAY[@]}"; do
  if [[ "$suite" == "tier2" ]]; then
    TOTAL_STORAGE=$((TOTAL_STORAGE + 10))
  else
    TOTAL_STORAGE=$((TOTAL_STORAGE + 2))
  fi
done
STORAGE_SIZE="${TOTAL_STORAGE}Gi"

ALLOWED_TEST_SUITES="compute|network|storage|ssp|tier2|csi"
if [[ ! "$TEST_SUITES" =~ ^($ALLOWED_TEST_SUITES)(,($ALLOWED_TEST_SUITES))*$ ]]; then
  echo "Invalid TEST_SUITES format: \"$TEST_SUITES\""
  echo "Allowed values: comma-separated list of [$ALLOWED_TEST_SUITES]"
  exit 1
fi


TEST_SKIPS=${TEST_SKIPS:-""}
TEST_FOCUS=${TEST_FOCUS:-""}

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
        echo "WARNING: '${f}' appears in both TEST_FOCUS and TEST_SKIPS. TEST_FOCUS takes precedence; test will run." >&2
      fi
    done
  done
fi

# Validate STORAGE_CAPABILITIES if provided
if [[ -n "${STORAGE_CAPABILITIES}" ]]; then
  valid_capabilities=("storageClassRhel" "storageClassWindows" "storageRWXBlock" "storageRWXFileSystem" "storageRWOFileSystem" "storageRWOBlock" "storageClassCSI" "storageSnapshot" "onlineResize" "WFFC")
  
  # Parse comma-separated capabilities
  IFS=',' read -ra capabilities_array <<< "${STORAGE_CAPABILITIES}"
  
  # Validate each capability
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    # Skip empty entries
    if [[ -z "$capability" ]]; then
      echo "Error: Empty storage capability found in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
    
    # Check if capability is valid
    valid=false
    for valid_cap in "${valid_capabilities[@]}"; do
      if [[ "$capability" == "$valid_cap" ]]; then
        valid=true
        break
      fi
    done
    
    if [[ "$valid" == false ]]; then
      echo "Error: Invalid storage capability '${capability}' in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
  done
  
  # Ensure STORAGE_CLASS is provided when STORAGE_CAPABILITIES is used
  if [[ -z "${STORAGE_CLASS}" ]]; then
    echo "Error: STORAGE_CLASS must be set when using STORAGE_CAPABILITIES"
    exit 1
  fi
fi

# Validate PRIMARY_NETWORK_BINDING_PLUGIN format (must be a valid plugin name: alphanumeric, '-', '.')
if [[ -n "${PRIMARY_NETWORK_BINDING_PLUGIN}" && ! "${PRIMARY_NETWORK_BINDING_PLUGIN}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "Error: Invalid PRIMARY_NETWORK_BINDING_PLUGIN value: '${PRIMARY_NETWORK_BINDING_PLUGIN}'"
  echo "Expected: a valid plugin name (alphanumeric characters, '-', '.', must start with alphanumeric)"
  exit 1
fi

HARNESS_INIT_CONTAINER=""
HARNESS_ASSET_MOUNTS=""
HARNESS_ASSET_VOLUME=""
if [[ ",${TEST_SUITES}," == *,csi,* ]] && [[ "${DRY_RUN}" != "true" ]]; then
  HARNESS_INIT_CONTAINER=$(cat <<EOF
      initContainers:
        - name: harness-assets
          image: ${HARNESS_IMAGE}
          imagePullPolicy: Always
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              mkdir -p /harness-assets/bin /harness-assets/csi /harness-assets/opt /harness-assets/python/lib
              cp /usr/bin/harness /usr/bin/kube-burner /usr/bin/kube-burner-ocp /usr/bin/virtctl /usr/bin/oc /usr/bin/kubectl /harness-assets/bin/
              cp /opt/harness/checkup/csi/* /harness-assets/csi/
              cp -R /opt/virtbench-venv /harness-assets/opt/virtbench-venv
              cp -R /opt/virtbench-runtime /harness-assets/opt/virtbench-runtime
              cp /usr/bin/python3.12 /harness-assets/python/python3.12
              cp /usr/lib64/libpython3.12.so.1.0 /harness-assets/python/libpython3.12.so.1.0
              cp -R /usr/lib64/python3.12 /harness-assets/python/stdlib
              cp -L /lib64/libcrypto.so.3 /harness-assets/python/lib/libcrypto.so.3
              cp -L /lib64/libssl.so.3 /harness-assets/python/lib/libssl.so.3
              chmod 0755 /harness-assets/bin/*
          volumeMounts:
            - name: harness-assets
              mountPath: /harness-assets
EOF
)
  HARNESS_ASSET_MOUNTS=$(cat <<EOF
            - name: harness-assets
              mountPath: /harness-assets
            - name: harness-assets
              mountPath: /opt/virtbench-venv
              subPath: opt/virtbench-venv
            - name: harness-assets
              mountPath: /usr/bin/python3.12
              subPath: python/python3.12
            - name: harness-assets
              mountPath: /usr/lib64/libpython3.12.so.1.0
              subPath: python/libpython3.12.so.1.0
            - name: harness-assets
              mountPath: /usr/lib64/python3.12
              subPath: python/stdlib
            - name: harness-assets
              mountPath: /opt/virtbench-runtime
              subPath: opt/virtbench-runtime
            - name: harness-assets
              mountPath: /opt/virtbench-python-libs
              subPath: python/lib
EOF
)
  HARNESS_ASSET_VOLUME=$(cat <<EOF
        - name: harness-assets
          emptyDir: {}
EOF
)
fi


# Namespace
cat <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-virt-validation
spec: {}
EOF

# Service Account
cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ocp-virt-validation-sa
  namespace: ocp-virt-validation
EOF

# RBAC
cat <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ocp-virt-validation-cluster-admin-binding
subjects:
  - kind: ServiceAccount
    name: ocp-virt-validation-sa
    namespace: ocp-virt-validation
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# PVC (to store the results)
# cdi.kubevirt.io/applyStorageProfile: "true" lets CDI apply StorageProfile so requested size is raised to the CSI driver minimum when smaller.
cat <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ocp-virt-validation-pvc-${TIMESTAMP}
  namespace: ocp-virt-validation
  labels:
    app: ocp-virt-validation
    cdi.kubevirt.io/applyStorageProfile: "true"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF

# Job
cat <<EOF
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-${TIMESTAMP}
  namespace: ocp-virt-validation
spec:
  template:
    metadata:
      labels:
        app: ocp-virt-validation
    spec:
      serviceAccountName: ocp-virt-validation-sa
      terminationGracePeriodSeconds: 60
      securityContext:
        fsGroup: 1001
${HARNESS_INIT_CONTAINER}
      containers:
        - name: ocp-virt-validation-checkup
          image: ${OCP_VIRT_VALIDATION_IMAGE}
          imagePullPolicy: Always
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: DRY_RUN
              value: "${DRY_RUN}"
            - name: TIMESTAMP
              value: ${TIMESTAMP}
            - name: RESULTS_DIR
              value: /results
            - name: TEST_SUITES
              value: ${TEST_SUITES}
            - name: TEST_SKIPS
              value: ${TEST_SKIPS}
            - name: TEST_FOCUS
              value: ${TEST_FOCUS}
            - name: FULL_SUITE
              value: "${FULL_SUITE}"
            - name: STORAGE_CLASS
              value: ${STORAGE_CLASS}
            - name: STORAGE_CAPABILITIES
              value: ${STORAGE_CAPABILITIES}
            - name: ACCEPT_WINDOWS_EULA
              value: "${ACCEPT_WINDOWS_EULA}"
            - name: WIN_IMAGE_DOWNLOAD_URL
              value: "${WIN_IMAGE_DOWNLOAD_URL}"
            - name: TEKTON_PIPELINE_VERSION
              value: "${TEKTON_PIPELINE_VERSION}"
            - name: PRIMARY_NETWORK_BINDING_PLUGIN
              value: "${PRIMARY_NETWORK_BINDING_PLUGIN}"
          volumeMounts:
            - name: results-volume
              mountPath: /results
${HARNESS_ASSET_MOUNTS}
      restartPolicy: Never
      volumes:
        - name: results-volume
          persistentVolumeClaim:
            claimName: ocp-virt-validation-pvc-${TIMESTAMP}
${HARNESS_ASSET_VOLUME}
  backoffLimit: 0
EOF
