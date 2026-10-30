# vCluster provider

> This provider is maintained by vCluster Labs, not by NVIDIA. NVIDIA does not
> endorse or support it. Report issues at
> <https://github.com/loft-sh/ai-cloud-validation-provider/issues>.

Connects [vCluster](https://www.vcluster.com) to the
[NVIDIA AI Cloud Validation Suite](https://github.com/NVIDIA/ai-cloud-validation)
for the `k8s` and `control-plane` suites.

vCluster runs a Virtual Control Plane (API server, scheduler, controller
manager) for each tenant on an existing Kubernetes cluster, the control plane
cluster. This provider validates the Shared Nodes tenancy model: the tenant's
cluster runs its workloads, GPU workloads included, on the control plane
cluster's nodes, which vCluster syncs into the tenant's cluster
(`sync.fromHost.nodes`).

Shared Nodes suit trusted tenants such as internal teams and development, test,
and CI/CD environments. AI Clouds that give external tenants Kubernetes or
workload access should give each tenant dedicated nodes with Private Nodes,
which this provider does not validate yet.

## Suites

| Suite | Config | What it exercises |
|---|---|---|
| `control-plane` | [`config/control-plane.yaml`](config/control-plane.yaml) | Tenant lifecycle (a tenant is a vCluster instance) and access keys (a ServiceAccount with a bound token) |
| `k8s` | [`config/k8s.yaml`](config/k8s.yaml) | The tenant's cluster on the control plane cluster's GPU nodes: nodes and GPUs, network policy, API network ACL, identity, observability, CNCF conformance, NCCL, GPU stress and NIM workloads |

## Prerequisites

The control plane cluster needs:

- NVIDIA GPU nodes exposed through the NVIDIA device plugin or the GPU Operator
- A CNI that enforces NetworkPolicies, for example GKE `--enable-network-policy`
- LoadBalancer Services that honor `loadBalancerSourceRanges`: on cloud clusters
  `setup.sh` exposes the tenant's API server through one, restricted to an
  allowlist

On the machine that runs the suites:

| Tool | Version | Purpose |
|---|---|---|
| `uv` | recent | Runs ai-cloud-validation |
| `vcluster` CLI | matching `VCLUSTER_VERSION` | Creates and connects to the tenant's cluster |
| `kubectl` | 1.28 or newer | Kubernetes client |
| `helm` | 3.14 or newer, 3.x | GPU Operator (when needed) and NIM charts |
| `jq`, `python3`, `curl` | any | Used by the setup and teardown scripts |

Everything `setup.sh` and the control-plane scripts enable is in open-source
vCluster, so no vCluster Platform login or license is needed.

The API allowlist defaults to this machine's public IPv4 address, so that
address must not change during a run. Otherwise set `VCLUSTER_API_ALLOWED_CIDRS`
to a stable range, such as your office or VPN egress.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `KUBECONFIG` | yes | | Kubeconfig of the control plane cluster |
| `KUBECTL` | `k8s` suite | | `kubectl --kubeconfig=<VCLUSTER_KUBECONFIG_PATH>`, so the validations probe the tenant's cluster |
| `NGC_API_KEY` | `k8s` suite | | NGC API key for nvcr.io pulls and the NIM workloads |
| `VCLUSTER_VERSION` | no | `0.37.5` | vCluster chart version that `setup.sh` and `create_tenant.py` deploy |
| `VCLUSTER_DRIVER` | no | `helm` | vcluster CLI driver; `helm` deploys into the control plane cluster even if your CLI defaults to Docker |
| `VCLUSTER_NAME` | no | `acv-tenant` | Name of the vCluster instance. Keep it at 14 characters or less (see [CNCF conformance](#cncf-conformance)) |
| `VCLUSTER_NAMESPACE` | no | `vcluster-isv-validation` | Its namespace on the control plane cluster |
| `VCLUSTER_KUBECONFIG_PATH` | no | `/tmp/vcluster-isv-validation.kubeconfig` | Where `setup.sh` writes the tenant's kubeconfig |
| `VCLUSTER_EXPOSE` | no | auto-detected | `true` exposes the tenant's API server through a LoadBalancer |
| `VCLUSTER_API_ALLOWED_CIDRS` | no | this machine's public IPv4 `/32` | Comma-separated CIDRs the API LoadBalancer admits |
| `CLOUD_PROVIDER` | no | auto-detected | `gke` enables the GKE GPU handling described below |
| `SKIP_PREFLIGHT` | no | `false` | `true` skips the GPU readiness waits |
| `VCLUSTER_HOST_KUBECONFIG` | no | `KUBECONFIG` | Control plane cluster kubeconfig for the `control-plane` suite |

## Reproducing

Run from an ai-cloud-validation checkout at the release the registry entry
names in `tested_with`:

```bash
git clone --branch v1.0.0 https://github.com/NVIDIA/ai-cloud-validation.git
cd ai-cloud-validation
uv sync
uv run isvctl provider fetch vcluster   # checks out the registered commit
export KUBECONFIG=/path/to/control-plane-cluster.kubeconfig

uv run isvctl test run --provider vcluster --suite control-plane

NGC_API_KEY="$(cat /path/to/ngc-api-key)" \
KUBECTL="kubectl --kubeconfig=/tmp/vcluster-isv-validation.kubeconfig" \
  uv run isvctl test run --provider vcluster --suite k8s
```

Before the registry entry exists, clone this repository next to the checkout
and pass the config path instead of `--provider`, from the checkout root:

```bash
uv run isvctl test run -f ../ai-cloud-validation-provider/vcluster/config/control-plane.yaml
```

Add `--phase setup|test|teardown` to run one phase of the `k8s` suite. Teardown
deletes the vCluster instance and restores the GPU node taints.

### Reference environment

| | |
|---|---|
| Control plane cluster | GKE Standard, zonal, Kubernetes 1.36, Calico network policy, COS nodes |
| GPU stack | NVIDIA GPU Operator v26.7.2 on the control plane cluster, as [NVIDIA documents for GKE COS](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/google-gke.html): GKE installs the driver, GKE's own device plugin is disabled, the operator runs the device plugin, GFD and toolkit (CDI); GKE's managed DCGM exporter collects GPU metrics |
| vCluster | 0.37.5, tenant's cluster on Kubernetes 1.36.6 |
| `default-pool` | 2x e2-standard-4 |
| `gpu-t4-pool` | 2x n1-standard-4, 1x NVIDIA T4 16 GB each: GPU, NCCL, stress and NIM workloads |

### Preparing a GKE control plane cluster

```bash
gcloud container clusters create <cluster> --zone <zone> --release-channel regular \
  --machine-type e2-standard-4 --num-nodes 2 --enable-network-policy
gcloud container node-pools create gpu-t4-pool --cluster <cluster> --zone <zone> \
  --machine-type n1-standard-4 --num-nodes 2 --disk-size 200 \
  --accelerator type=nvidia-tesla-t4,count=1,gpu-driver-version=default \
  --node-labels=gke-no-default-nvidia-gpu-device-plugin=true

# GPU Operator: GKE's driver, the operator's device plugin, GFD and toolkit
kubectl create namespace gpu-operator
kubectl apply -n gpu-operator -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-operator-quota
spec:
  hard:
    pods: 100
  scopeSelector:
    matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values: [system-node-critical, system-cluster-critical]
EOF
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator --version v26.7.2 -n gpu-operator --wait \
  --set driver.enabled=false --set cdi.enabled=true --set cdi.default=true \
  --set hostPaths.driverInstallDir=/home/kubernetes/bin/nvidia \
  --set toolkit.installDir=/home/kubernetes/bin/nvidia \
  --set 'toolkit.env[0].name=RUNTIME_CONFIG_SOURCE' --set 'toolkit.env[0].value=file' \
  --set dcgmExporter.enabled=false
```

NVIDIA's guide installs the COS driver with Google's driver installer
DaemonSet and `gpu-driver-version=disabled`; letting GKE install it
(`gpu-driver-version=default`) puts the same driver in the same place. The
`RUNTIME_CONFIG_SOURCE=file` toolkit setting is NVIDIA's workaround for GKE 1.33
and newer. GKE already runs a managed DCGM exporter on GPU nodes, and two DCGM
instances cannot both watch the profiling metrics, so the operator's DCGM
exporter is disabled.

## Results

Validation against ai-cloud-validation 1.0.0 is in progress. This section will
list the results of that run.

## How the provider runs the `k8s` suite

- **vCluster configuration.** `setup.sh` follows vCluster's
  [CNCF-certified Shared Nodes configuration](https://github.com/cncf/k8s-conformance/tree/master/v1.36/vcluster-with-shared-nodes)
  (virtual scheduler, chart-deployed etcd, real node addresses,
  PersistentVolume, PriorityClass and StorageClass sync) and adds what GPU workloads need: node sync with all
  labels and capacity, NetworkPolicy sync, and an `nvidia` RuntimeClass. The
  tenant's API server runs with `--enable-aggregator-routing=true`, so it calls
  webhooks and aggregated APIs on their endpoint IPs, as managed control planes
  do, instead of on Service ClusterIPs that the control plane cluster's
  kube-proxy may not have programmed yet.
- **GPU access.** On GKE COS nodes containerd has no `nvidia` runtime handler,
  so GPU pods only request `nvidia.com/gpu` and the workloads set
  `runtime_class_name: ""`.
- **GPU Operator.** The GPU stack (the GPU Operator, or on GKE the managed
  drivers and device plugin) belongs to the control plane cluster and its
  platform operator. When its nodes already advertise `nvidia.com/gpu`,
  installing the GPU Operator in the tenant's cluster would sync a second device
  plugin onto the same nodes, so `setup.sh` installs nothing there, and
  `K8sGpuOperatorNamespaceCheck` and `K8sGpuOperatorPodsCheck` fail by design.
  When the control plane cluster has no GPU stack, `setup.sh` installs the GPU
  Operator with `driver.enabled=false`.
- **GPU labels and driver version.** The suite finds GPU nodes by GPU Feature
  Discovery's `nvidia.com/gpu.present=true` label and reads the driver version
  from GFD's `nvidia.com/cuda.driver.*` labels, so the reference environment
  runs the GPU Operator. On GKE without it, `setup.sh` points
  `K8sGpuLabelsCheck` at GKE's own `cloud.google.com/gke-accelerator` label and
  reports no driver version, which makes `K8sDriverVersionCheck` skip; GPU node
  discovery in `K8sGpuPodAccessCheck` still needs GFD.
- **API network ACL.** On cloud clusters the tenant's API server is reachable
  only through a LoadBalancer whose `loadBalancerSourceRanges` admit
  `VCLUSTER_API_ALLOWED_CIDRS`. `K8sApiNetworkAclCheck` requires kubectl from
  the runner to succeed and a request from a pod in the cluster, outside the
  allowlist, to be blocked. Any HTTP answer, a 401 included, counts as
  reachable.
- **MIG.** `setup.sh` adds no `nvidia.com/mig.*` labels of its own. Where GPU
  Feature Discovery does not run, as on GKE COS, `K8sMigConfigCheck` finds no
  MIG nodes and skips.
- **MPI Operator.** `setup.sh` installs the bundled Kubeflow MPI Operator
  v0.5.0 (`manifests/`) with server-side apply for the multi-node NCCL workload.
- **GPU taints.** `setup.sh` removes `nvidia.com/gpu:NoSchedule` from the GPU
  nodes for the run, so the conformance BeforeSuite treats every node as
  schedulable. `teardown.sh` restores the taints.
- **Access keys.** An access key is a ServiceAccount with a bound token.
  Disabling it removes its ClusterRoleBinding, so the token gets 403. Deleting
  it removes both, and the `VCLUSTER_NAMESPACE` namespace too when
  `create_access_key.py` had to create it and nothing else lives there.

## Known gaps against the 1.0.0 suites

- **GPU Operator (K8S25-01, K8S25-02).** On Shared Nodes the GPU Operator and
  driver belong to the platform operator on the control plane cluster, so a
  tenant can neither see nor replace them. The namespace, pod and override
  checks fail: the tenant's cluster has no GPU Operator workloads and no
  ClusterPolicy or NVIDIADriver to override.
- **OIDC issuer (K8S17-02).** The check fetches the OIDC discovery document and
  JWKS anonymously from outside the cluster. The tenant's cluster advertises an
  in-cluster issuer, so the check fails unless the issuer is published at a
  public HTTPS URL.
- **DRA (K8S24-01).** Needs a DRA driver on the control plane cluster plus
  `sync.fromHost.deviceClasses` and `sync.toHost.resourceClaims`, which are
  vCluster Platform features. The reference environment uses the device plugin
  and open-source vCluster, so the check fails.
- **Steps not wired.** Node pools, `reset_gpus` and `cordon_node` act on the
  control plane cluster's nodes, which the platform operator manages.
  Control-plane sizing, version listing, patching, upgrades, service account
  IAM and the networking probes need vCluster-specific implementations. Their
  checks report `step_not_configured`. In the `control-plane` suite vCluster has
  no object storage API, so `ObjectStorageCrudCheck` reports
  `step_not_configured`.

## CNCF conformance

`K8sCncfConformanceCheck` runs in `certified-conformance` mode. A run with no
skips on the reference environment ran 443 `[Conformance]` specs: 439 passed and
4 failed. `config/k8s.yaml` skips one of them, for a vCluster bug, and the
provider's configuration fixes the other three:

| Failing spec | Cause | Handling |
|---|---|---|
| Pod Generation: 500 podspec updates, `observedGeneration` converges | vCluster 0.37.5 copies the host pod's `status.observedGeneration` into the tenant's pod. The syncer folds rapid updates together, so the host pod ends at generation 490 while the tenant's pod is at 500, and the values never converge | Skipped |
| EndpointSlice: multiple endpoint IPs, and multiple ports, in multiple EndpointSlices | vCluster 0.37.5 builds the host EndpointSlice's `kubernetes.io/service-name` label without the hashing it applies to host Service names over 63 characters. With a long tenant name the label is invalid and the selector-less Service gets no endpoints | Pass with the default `VCLUSTER_NAME`, `acv-tenant`. Keep it at 14 characters or less |
| CustomResourceConversionWebhook (either spec, intermittently) | The tenant's API server called the new webhook Service by ClusterIP before the control plane cluster's kube-proxy had programmed it (GKE resyncs at most every 10 s), and the blackholed connection outlasted the spec's 30 s wait | `--enable-aggregator-routing=true` (see above) |

vCluster is
[CNCF-certified](https://github.com/cncf/k8s-conformance/tree/master/v1.36) for
Kubernetes 1.28 through 1.36; the 1.35 and 1.36 certifications cover standalone,
Private Nodes and Shared Nodes configurations.

## Layout

```text
config/       suite configs: k8s.yaml, control-plane.yaml
scripts/k8s/  setup.sh, teardown.sh, and _common.sh (inventory helper, vendored
              from ai-cloud-validation v1.0.0 isvctl/configs/providers/my-isv)
scripts/control-plane/  tenant and access key lifecycle
manifests/    Kubeflow MPI Operator v0.5.0
```
