# ocp-virt-validation-checkup
This repository provides the necessary scripts and utilities to run a validation checkup of OpenShift Virtualization inside a customer environment.

## Objectives
* Run a stable subset of functional tests of [KubeVirt](https://github.com/kubevirt/kubevirt)'s main SIGs: Compute, Network, Storage, as well as [SSP](https://github.com/kubevirt/ssp-operator) test suite. These are also known as Tier-1 test suites.
* Self-sustained, unified package that contains all of the required code to run the validation checkup. The test code is fully aligned with the extact OpenShift Virtualization build installed on the cluster under test. The test suites are being run by a Job object, which runs to a completion.
* Run the test suites, with optional modifications, in a streamlined way.
* Get and browse the validation checkup results with little effort. The test suite results, logs and artifacts are being stored in a PersistentVolumeClaim. A summary of the results is being stored to a ConfigMap.


## Pre-requisites
* [OpenShift Container Platform (OCP)](https://www.redhat.com/en/technologies/cloud-computing/openshift) with [OpenShift Virtualization](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization) 4.19 (or above) installed.
* cluster-admin permissions.
* Valid credentials to Red Hat Registry (registry.redhat.io) - Must be logged in with valid Red Hat account:
```bash
$ podman login registry.redhat.io
```
A pull secret can be obtained from https://console.redhat.com/openshift/install/pull-secret  
* `oc` command line tool.
* For tests involving Virtual Machine live migration, a ReadWriteMany storage class should be available. e.g. [OpenShift Data Foundation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/storage/configuring-persistent-storage#red-hat-openshift-data-foundation).
* For storage test suite, a default VolumeSnapshotClass should be set.
* For SSP test suite, `enableCommonBootImageImport` in HyperConverged CR should be set to `false`.

## Usage
### Get the validation checkup image
On an OpenShift cluster with OpenShift Virtualization installed, get the validation-checkup image from the CSV of OpenShift Virtualization Operator:
```bash
$ CSV_NAME=$(oc get csv -n openshift-cnv -o json | jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name')
$ OCP_VIRT_VALIDATION_IMAGE=$(oc get csv -n openshift-cnv $CSV_NAME -o json | jq -r '.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image')
```

### Run the validation checkup
Once the OCP-Virt validation checkup image is obtained, run it to generate the manifests required to run the checkup.
Dump the run manifests to stdout:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate
```
This will generate the following manifests:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-virt-validation
spec: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ocp-virt-validation-sa
  namespace: ocp-virt-validation
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ocp-virt-validation-pvc-20250520-105358
  namespace: ocp-virt-validation
  labels:
    app: ocp-virt-validation
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-20250520-105358
  namespace: ocp-virt-validation
spec:
  template:
    metadata:
      labels:
        app: ocp-virt-validation
    spec:
      serviceAccountName: ocp-virt-validation-sa
      securityContext:
        fsGroup: 1001
      containers:
        - name: ocp-virt-validation-checkup
          image: registry.redhat.io/container-native-virtualization/ocp-virt-validation-checkup-rhel9:v4.19.0-28
          imagePullPolicy: Always
          env:
            - name: DRY_RUN
              value: "false"
            - name: TIMESTAMP
              value: 20250520-105358
            - name: RESULTS_DIR
              value: /results
            - name: TEST_SUITES
              value: compute,network,storage,ssp,tier2
            - name: TEST_SKIPS
              value: ""
          volumeMounts:
            - name: results-volume
              mountPath: /results
      restartPolicy: Never
      volumes:
        - name: results-volume
          persistentVolumeClaim:
            claimName: ocp-virt-validation-pvc-20250520-105358
  backoffLimit: 0
```
In order to apply these manifests directly onto the cluster in order to start the validation checkup, run:
```bash
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -
```
You can use output redirection to a file in order to make adjustments, if needed:
```bash
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate > run_manifests.yaml
```

### Make modifications
The default settings of the validation checkup can be modified before the execution.

#### Test Suites
By default, the validation checkup will run all of the test suites.  
It is possible to configure a subset of the suites to run. The available test suites are:
* `compute` - conformance tests with `sig-compute` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository.
* `network` - conformance tests with `sig-network` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository
* `storage` - conformance tests with `sig-storage` label + tests with `StorageCritical` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository
* `ssp` - tests from [ssp-operator](https://github.com/kubevirt/ssp-operator/tree/main/tests) repository.
* `tier2` - Conformance tests from [openshift-virtualization-tests](https://github.com/RedHatQE/openshift-virtualization-tests) repository.

Use the `TEST_SUITES` environment variable, with a comma separated list of the desired suites, when running the `generate` script. The example below shows how to run only the `compute` and the `network` suites, by setting `TEST_SUITES` to `"compute,network"`:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e TEST_SUITES=compute,network,tier2 ${OCP_VIRT_VALIDATION_IMAGE} generate
```
This will configure the following environment variable for the job:
```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
        - name: ocp-virt-validation-checkup
          env:
            - name: TEST_SUITES
              value: compute,network,tier2
```

**Note:** the value passed to `TEST_SUITES` should be comma-separated.

Set `TEST_SUITES=csi` to run the bundled storage certification Harness plan as a sixth suite. This runs the `level3-customer-no-load-80` plan after the selected native suites; the five native suites remain the default. `TEST_FOCUS` and `TEST_SKIPS` do not filter the Harness plan. Set `HARNESS_IMAGE` when generating manifests to use a mirrored or development Harness image that includes the CSI assets and tools. The bundled plan is certification scale and its target-node and snapshot-batch inputs must be populated in the image; Harness preflight stops the suite before workload launch while placeholders remain.

The Harness flat JUnit report is copied to `csi/junit.results.xml` and read by Checkup’s existing result parser. Detailed Harness reports and logs are retained under `csi/harness` in the results archive.

#### Test Skips
In order to skip one or more test cases, a `TEST_SKIPS` environment variable can be specified.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e TEST_SKIPS="test_id:1783|test_id:1853" ${OCP_VIRT_VALIDATION_IMAGE} generate
```
**Note:** the value passed to `TEST_SKIPS` should be pipe-separated.

#### Test Focus
In order to run only specific test cases, a `TEST_FOCUS` environment variable can be specified. Only tests matching the provided patterns will be executed.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e TEST_FOCUS="test_id:1618|test_id:1783" ${OCP_VIRT_VALIDATION_IMAGE} generate
```
**Note:** the value passed to `TEST_FOCUS` should be pipe-separated, same as `TEST_SKIPS`.

If the same test appears in both `TEST_FOCUS` and `TEST_SKIPS`, a warning is printed and the test **will run** (`TEST_FOCUS` takes precedence).

#### Full Suite
By default, only a small, representative and most robust test cases are selected to run.  
In order to run all of the available tests, without filtering only to the conformance ones, the ` FULL_SUITE` environment variable can be set to `true`.  
_Warning_: Using `FULL_SUITE=true` might prolong the checkup run time significantly, and a large amount of test failures/errors are expected.  

#### Storage Class
In order to set the storage class that will be used throughout the test suites, a `STORAGE_CLASS` environment variable should be specified.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization ${OCP_VIRT_VALIDATION_IMAGE} generate
```
If no `STORAGE_CLASS` environment variable is set, the default storage class in the cluster will be used for the checkup.

**Note:** If the specified storage class is not recognized by the validation checkup and no `STORAGE_CAPABILITIES` are provided, the checkup will fail with an error message: *"The selected storage class was not found and neither STORAGE_CAPABILITIES have been provided"*. In such cases, you must either use a supported storage class or explicitly define the storage capabilities using the `STORAGE_CAPABILITIES` environment variable.

#### Storage Capabilities
The storage capabilities (such as: volume mode, access mode, snapshot support, etc.) are resolved based on the storage class name, using a predefined list of known storage providers. If the selected storage provider is not known, the `STORAGE_CAPABILITIES` env var must be passed, to instruct the tests what are the storage capabilities that should be put under tests.  
The syntax of `STORAGE_CAPABILITIES` env var is a comma-separated list of these properties:
- storageClassRhel
- storageClassWindows
- storageRWXBlock
- storageRWXFileSystem
- storageRWOFileSystem
- storageRWOBlock
- storageClassCSI
- storageSnapshot
- onlineResize
- WFFC

It is possible to set any subset of this list, according to the actual capabilities of the specified storage class.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e STORAGE_CLASS=my-awesome-sc -e STORAGE_CAPABILITIES=storageClassRhel,storageRWXFileSystem,storageRWOBlock,onlineResize ${OCP_VIRT_VALIDATION_IMAGE} generate
```
Which will produce the following Job yaml (only the relevant section is displayed):
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-20250810-101901
  namespace: ocp-virt-validation
spec:
  template:
    spec:
      containers:
        - name: ocp-virt-validation-checkup
          env:
            - name: STORAGE_CLASS
              value: my-awesome-sc
            - name: STORAGE_CAPABILITIES
              value: storageClassRhel,storageRWXFileSystem,storageRWOBlock,onlineResize
...
```

**Note:** If the provisioner is recognized by [CDI](https://github.com/kubevirt/containerized-data-importer), it is possible to get the the supported access mode and volume mode for a given Storage Class by checking its StorageProfile, e.g.
```
$ oc get storageprofile my-custom-sc -o yaml | yq .status.claimPropertySets
- accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
```
In this case, `storageRWXFileSystem` should be set.

**Note** If the `storageSnapshot` storage capability is not passed, tests that are requiring snapshots will fail with error. The snapshot tests are not skipped because they are a core functionality of OpenShift Virtualization.

#### Primary Network Binding Plugin
When running the `network` test suite with a custom network binding plugin, the `PRIMARY_NETWORK_BINDING_PLUGIN` environment variable can be set to the name of the binding plugin to test. This passes the `--primary-network-binding-plugin` flag to the upstream KubeVirt conformance tests, enabling CNI vendors and network binding plugin authors to certify their implementations.

When this parameter is set:
- Masquerade-specific tests (labeled `interface-ports`, `network-cidr`, `IPv6`) are excluded, as they are not applicable when a non-masquerade binding plugin is in use

Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
    -e TEST_SUITES=network \
    -e PRIMARY_NETWORK_BINDING_PLUGIN=my-binding-plugin \
    ${OCP_VIRT_VALIDATION_IMAGE} generate
```

#### Dry Run
In order to see which tests are going to be run, without actually executing them on the cluster, a `DRY_RUN` environment variable can be set:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e DRY_RUN=true ${OCP_VIRT_VALIDATION_IMAGE} generate
```

### Windows Testing (Optional)

The validation checkup supports optional Windows VM testing. There are two options:

**Note:** Both options below require **internet access** (connected cluster). For disconnected environments, provide your own pre-built Windows golden image (BYOI) with SSH and guest agent pre-installed. See [`disconnected/README.md`](disconnected/README.md) for details.

#### Option 1: Customer-Managed (Apply Manifest)

A ready-to-use manifest is provided that creates a Windows Server 2022 golden image from scratch using a Tekton pipeline. It includes namespace, RBAC, sysprep configuration, and a PipelineRun — single `oc apply`, full automation.

**Prerequisites:**
- **OpenShift Pipelines operator** must be installed
- **cluster-admin** access (for privileged SCC assignment)
- **Internet access** to download the Windows ISO and fetch the pipeline from Artifact Hub
- **Sufficient storage** (~64GB recommended for the Windows image)

**Setup:**

1. Apply the manifest:
```bash
oc apply -f manifests/windows/golden-image.yaml
```
2. Wait for the pipeline to complete (~1-2 hours):
```bash
oc get pipelinerun -n validation-os-images -w
```
3. Verify the DataSource is Ready:
```bash
oc get datasource win2k22 -n validation-os-images -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```
4. Run the tool normally (no `ACCEPT_WINDOWS_EULA` needed):
```bash
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -
```

The tool detects the existing DataSource and runs Windows tests automatically. After tests complete, **nothing is deleted** — your resources remain for future runs.

The manifest also includes a commented-out alternative (Method 2) for users who already have a prepared Windows image and want to import via HTTP, registry, or upload.

See [`manifests/windows/golden-image.yaml`](manifests/windows/golden-image.yaml) for full details and image requirements.

#### Option 2: Automated (Tool Creates Everything)

The tool downloads a Windows Server 2022 ISO, runs a Tekton pipeline to install it, and creates all resources. Everything is cleaned up after tests finish.

**Prerequisites:**
- **OpenShift Pipelines operator** must be installed
- **Internet access** to download the ISO and fetch the pipeline from Artifact Hub
- **Sufficient storage** (~64GB recommended)
- **`STORAGE_CLASS`** set to a valid storage class

**Usage:**
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
    -e ACCEPT_WINDOWS_EULA=true \
    -e STORAGE_CLASS=<your-storage-class> \
    ${OCP_VIRT_VALIDATION_IMAGE} generate
```

**Note:** By setting `ACCEPT_WINDOWS_EULA=true`, you acknowledge acceptance of Microsoft's End User License Agreement for Windows.

**Optional Parameters:**

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `ACCEPT_WINDOWS_EULA` | Enable Windows testing (must be `true` to enable) | `false` |
| `WIN_IMAGE_DOWNLOAD_URL` | Custom Windows Server 2022 ISO download URL | Default Microsoft URL |
| `TEKTON_PIPELINE_VERSION` | Version of the `windows-efi-installer` pipeline | `>=v4.21.0` |

Example with custom ISO URL:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
    -e ACCEPT_WINDOWS_EULA=true \
    -e STORAGE_CLASS=<your-storage-class> \
    -e WIN_IMAGE_DOWNLOAD_URL="https://my-internal-server/SERVER_EVAL_x64FRE_en-us.iso" \
    ${OCP_VIRT_VALIDATION_IMAGE} generate
```

**How It Works:**
1. The checkup verifies that the OpenShift Pipelines operator is installed
2. Creates the `validation-os-images` namespace, RBAC, and runs the `windows-efi-installer` Tekton pipeline
3. The pipeline downloads the ISO and installs Windows Server 2022 with OpenSSH, QEMU guest agent, and firewall disabled
4. A DataSource (`win2k22`) is created backed by the output PVC
5. A temporary VM (`win-ssh-verify-*`) boots from the golden image to verify SSH (port 22) is reachable. If verification fails the entire checkup aborts — check `C:\post-update.log` inside the golden image for diagnosis.
6. The tier2 test suite runs tests matching `@pytest.mark.conformance`; when no golden image is available, tests with `@pytest.mark.windows` are excluded
7. After tests complete, the entire `validation-os-images` namespace is deleted

**Note:** The initial Windows image creation takes approximately 1-2 hours (up to 3 hours on slow networks).

## Disconnected Environments
The validation checkup can be run on disconnected (air-gapped) OpenShift clusters by mirroring the required test images to an accessible registry and configuring mirror sets (ITMS + IDMS). No changes to the checkup configuration are needed -- mirror sets transparently redirect image pulls at the CRI-O level.

For full instructions, including which images to mirror, mirroring commands, mirror set configuration, and using the OpenShift internal registry, see the **[Disconnected Environments Guide](disconnected/README.md)**.

A helper script at [`disconnected/mirror-images.sh`](disconnected/mirror-images.sh) automates the entire process.


## Retrieve Checkup Results
The checkup results are available both in the form of a summary, and a browsable detailed results.

### Results Summary
Once the validation checkup finishes, a ConfigMap is being created at the `ocp-virt-validation` namespace with a summary of all results.  
The config map includes a yaml which is divided to a section for each executed test suite, as well as a summary section.  
Example:
```yaml
compute:
  failed_tests:
  - '[rfe_id:393][crit:high][vendor:cnv-qe@redhat.com][level:system][sig-compute]
    VM Live Migration Starting a VirtualMachineInstance  with a Alpine disk [test_id:1783]should
    be successfully migrated multiple times with cloud-init disk'
  - '[rfe_id:393][crit:high][vendor:cnv-qe@redhat.com][level:system][sig-compute]
    VM Live Migration with sata disks [test_id:1853]VM with containerDisk + CloudInit
    + ServiceAccount + ConfigMap + Secret + DownwardAPI + External Kernel Boot + USB
    Disk'
  - '[rfe_id:1177][crit:medium][vendor:cnv-qe@redhat.com][level:component][sig-compute]VirtualMachine
    A valid VirtualMachine given [test_id:1521]should remove VirtualMachineInstance
    once the VM is marked for deletion [storage-req]with Filesystem Disk'
  tests_failures: 3
  tests_passed: 63
  tests_run: 66
  tests_skipped: 0
network:
  failed_tests:
  - '[sig-network] network binding plugin with domain attachment managedTap type can
    establish communication between two VMs'
  tests_failures: 1
  tests_passed: 151
  tests_run: 152
  tests_skipped: 0
ssp:
  failed_tests:
  - '[It] DataSources rbac os-images With Edit permission should verify resource permissions
    [test_id:4774]: ServiceAcounts with edit role can create PVCs'
  - '[It] Prometheus Alerts VMStorageClassWarning [test_id:TODO] Should not fire VMStorageClassWarning
    when rxbounce is enabled'
  tests_failures: 2
  tests_passed: 294
  tests_run: 299
  tests_skipped: 3
storage:
  tests_failures: 0
  tests_passed: 15
  tests_run: 15
  tests_skipped: 0
summary:
  total_tests_failed: 6
  total_tests_passed: 526
  total_tests_run: 532
```

### Detailed Results
In order to view the detailed results of the validation checkup execution once the Job finishes, an nginx server that mounts the PVC should be set up.  
To do so, the timestamp of the last execution should first be retrieved:  
```bash
$ TIMESTAMP="$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}')"
```
Then, use that timestamp and run:  
```bash
$ podman run -e TIMESTAMP=${TIMESTAMP} ${OCP_VIRT_VALIDATION_IMAGE} get_results
```
This command will generate the required manifests to set up an nginx server and expose it through a Route.  
The command output would look similar to:  
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pvc-reader-nginx-conf
  namespace: ocp-virt-validation
data:
  nginx.conf: |-
    user nginx;
    worker_processes auto;

    error_log /var/log/nginx/error.log warn;
    pid /var/run/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        log_format main ' -  [] "" '
                          '  "" '
                          '"" ""';

        access_log /var/log/nginx/access.log main;

        sendfile on;

        keepalive_timeout 65;

        server {
            listen 8080;

            location / {
                alias /results/;
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
                location ~ /\.\./ {
                    deny all;
                }
            }
        }
    }
---
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: pvc-reader
  name: pvc-reader-20250518-112311
  namespace: ocp-virt-validation
spec:
  containers:
    - image: registry.redhat.io/rhel9/nginx-124:latest
      name: pod
      command:
        - "sh"
        - "-c"
        - "nginx -g \"daemon off;\""
      volumeMounts:
        - mountPath: /results
          name: results
        - name: conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
  volumes:
    - name: results
      persistentVolumeClaim:
        claimName: ocp-virt-validation-pvc-20250518-112311
    - name: conf
      configMap:
        name: pvc-reader-nginx-conf
        items:
          - key: nginx.conf
            path: nginx.conf
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: pvc-reader
  name: pvc-reader
  namespace: ocp-virt-validation
spec:
  ports:
    - name: nginx
      port: 8080
      protocol: TCP
      targetPort: 8080
  selector:
    app: pvc-reader
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pvcreader
  namespace: ocp-virt-validation
spec:
  path: /
  port:
    targetPort: 8080
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: pvc-reader
    weight: 100
  wildcardPolicy: None
  # ---
  # to view the results, visit the route endpoint:
  # oc get route pvcreader -n ocp-virt-validation -o jsonpath='{.status.ingress[0].host}'
```
**Note:** You can apply the manifests directly from the command, using:
```bash
$ podman run -e TIMESTAMP=${TIMESTAMP} ${OCP_VIRT_VALIDATION_IMAGE} get_results | oc apply -f -
configmap/pvc-reader-nginx-conf created
pod/pvc-reader-20250518-112311 created
service/pvc-reader created
route.route.openshift.io/pvcreader created
```
The Route leading to the nginx server hosting the detailed results will be available at:  
```bash
$ oc get route pvcreader -n ocp-virt-validation -o jsonpath='{.status.ingress[0].host}'
```
The nginx server hosts a file directory, containing a directory for every executed test suite.  
For each subdirectory (compute, network, storage, ssp), there are:
* The full ginkgo log of the run
* JUnit file
* k8s-reporter folder, containing artifacts of the failed test runs.

In addition, a compressed `tar.gz` file is provided at the root directory, allowing the user to download it and browse the results locally.

**Note**
Instead of using the Route for the PVC Reader nginx server, you can use the following command to access it:
```bash
$ oc port-forward service/pvc-reader 8080:8080 -n ocp-virt-validation
```
And then the results will be accessible through http://localhost:8080
