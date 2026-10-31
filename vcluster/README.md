# vCluster provider

> This provider is maintained by vCluster Labs, not by NVIDIA. NVIDIA does not
> endorse or support it. Report issues at
> <https://github.com/loft-sh/ai-cloud-validation-provider/issues>.

Connects [vCluster](https://www.vcluster.com) to the
[NVIDIA AI Cloud Validation Suite](https://github.com/NVIDIA/ai-cloud-validation)
for the `k8s` and `control-plane` suites.

vCluster gives each tenant its own Kubernetes cluster: a Virtual Control Plane
(API server, scheduler, controller manager) that runs on an existing Kubernetes
cluster, the control plane cluster. This provider validates vCluster's Private
Nodes tenancy model, the model for AI Clouds whose tenants get Kubernetes or
workload access. Dedicated GPU nodes join the tenant's cluster, which runs its
own CNI, NVIDIA GPU Operator and DRA driver. No tenant workload runs on, and
nothing is synced to, the control plane cluster's nodes.

## Suites

| Suite | Config | What it exercises |
|---|---|---|
| `control-plane` | [`config/control-plane.yaml`](config/control-plane.yaml) | Tenant lifecycle (a tenant is a vCluster instance with Private Nodes) and access keys (a ServiceAccount with a bound token) |
| `k8s` | [`config/k8s.yaml`](config/k8s.yaml) | The tenant's cluster on its own GPU nodes: nodes and GPUs, GPU Operator, DRA, network policy, API network ACL, identity, observability, CNCF conformance, NCCL, GPU stress and NIM workloads |

## Prerequisites

**Control plane cluster.** Any Kubernetes cluster that can publish a
LoadBalancer Service the worker nodes can reach and that honors
`loadBalancerSourceRanges`. It hosts the tenant's Virtual Control Plane;
it needs no GPUs.

**vCluster Platform.** Private Nodes is a vCluster Free tier feature, licensed
through vCluster Platform at no cost:

1. Install the Platform, for example on the control plane cluster with
   `vcluster platform start --email <you@example.com>`.
2. Log in to its UI and activate the instance with the code it emails you.
   Until then the license blocks creating tenants ("license limits are
   exceeded").
3. Create an access key that can create `VirtualClusterInstance` resources in
   a project. A key scoped to only the `vcluster` and `loft-cli` roles cannot.

**Worker nodes.** Machines with NVIDIA GPUs, running an OS vCluster supports for
[Private Nodes](https://www.vcluster.com/docs/vcluster/deploy/worker-nodes/private-nodes/node-requirements)
(Ubuntu 22.04 or 24.04, RHEL 8 to 10, Rocky, CentOS Stream), with no Kubernetes
installed and outbound internet access for images. The runner reaches them over
SSH as a user with passwordless sudo. The NVIDIA driver comes from the GPU
Operator.

**Runner**, the machine that runs the suites:

| Tool | Version | Purpose |
|---|---|---|
| `uv` | recent | Runs ai-cloud-validation |
| `vcluster` CLI | matching `VCLUSTER_VERSION` | Creates the tenant, logs in to the Platform, creates node join tokens |
| `kubectl` | 1.28 or newer | Kubernetes client |
| `helm` | 3.x | Calico, GPU Operator, DRA driver and NIM charts |
| `ssh`, `jq`, `python3`, `curl` | any | Used by the setup and teardown scripts |

The API allowlist defaults to the public IPv4 addresses of the runner and the
worker nodes, so they must not change during a run. Otherwise set
`VCLUSTER_API_ALLOWED_CIDRS` to stable ranges.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `KUBECONFIG` | yes | | Kubeconfig of the control plane cluster |
| `VCLUSTER_PLATFORM_HOST` | yes | | vCluster Platform URL |
| `VCLUSTER_PLATFORM_ACCESS_KEY` | yes | | Platform access key (or `VCLUSTER_PLATFORM_ACCESS_KEY_FILE`) |
| `VCLUSTER_PLATFORM_INSECURE` | no | `false` | `true` for a Platform with a self-signed certificate |
| `VCLUSTER_NODES` | `k8s` suite | | Space-separated SSH destinations (`user@host`) of the worker nodes |
| `VCLUSTER_NODE_SSH_KEY` | no | ssh's own | Private key for the worker nodes |
| `VCLUSTER_NODE_SSH_OPTS` | no | | Extra ssh options, for example `-o UserKnownHostsFile=...` |
| `KUBECTL` | `k8s` suite | | `kubectl --kubeconfig=<VCLUSTER_KUBECONFIG_PATH>`, so the validations probe the tenant's cluster |
| `NGC_API_KEY` | `k8s` suite | | NGC API key for nvcr.io pulls and the NIM workloads |
| `VCLUSTER_VERSION` | no | `0.37.6` | vCluster chart version that `setup.sh` and `create_tenant.py` deploy |
| `VCLUSTER_NAME` | no | `acv-tenant` | Name of the vCluster instance |
| `VCLUSTER_NAMESPACE` | no | `vcluster-isv-validation` | Its namespace on the control plane cluster |
| `VCLUSTER_KUBECONFIG_PATH` | no | `/tmp/vcluster-isv-validation.kubeconfig` | Where `setup.sh` writes the tenant's kubeconfig (mode 600) and, next to it, its other state. On a shared machine, point it at a private directory |
| `VCLUSTER_API_ALLOWED_CIDRS` | no | runner and nodes, each `/32` | Comma-separated CIDRs the API LoadBalancer admits |
| `VCLUSTER_POD_CIDR`, `VCLUSTER_SERVICE_CIDR` | no | `172.20.0.0/16`, `172.21.0.0/16` | The tenant's pod and Service ranges; keep them clear of the nodes' network |
| `CALICO_VERSION`, `GPU_OPERATOR_VERSION`, `DRA_DRIVER_VERSION` | no | `v3.32.3`, `v26.7.2`, `25.12.0` | Releases `setup.sh` installs in the tenant's cluster |
| `VCLUSTER_OIDC_ISSUER_URL`, `VCLUSTER_OIDC_PUBLISH_CMD` | no | | A public service account issuer, see [OIDC issuer](#known-gaps-against-the-100-suites) |
| `VCLUSTER_DRIVER` | no | `helm` | vcluster CLI driver for the `control-plane` suite |
| `VCLUSTER_HOST_KUBECONFIG` | no | `KUBECONFIG` | Control plane cluster kubeconfig for the `control-plane` suite |

## Reproducing

The results below were produced against ai-cloud-validation v1.0.0, the
release the registry entry names in `tested_with`. That tag predates the
`vcluster` registry entry, so clone this repository next to it and pass the
config path, from the checkout root:

```bash
git clone --branch v1.0.0 https://github.com/NVIDIA/ai-cloud-validation.git
git clone https://github.com/loft-sh/ai-cloud-validation-provider.git
cd ai-cloud-validation
uv sync
export KUBECONFIG=/path/to/control-plane-cluster.kubeconfig
export VCLUSTER_PLATFORM_HOST=https://platform.example.com
export VCLUSTER_PLATFORM_ACCESS_KEY_FILE=/path/to/platform-access-key

uv run isvctl test run -f ../ai-cloud-validation-provider/vcluster/config/control-plane.yaml

VCLUSTER_NODES="ubuntu@gpu-1.example.com ubuntu@gpu-2.example.com" \
NGC_API_KEY="$(cat /path/to/ngc-api-key)" \
KUBECTL="kubectl --kubeconfig=/tmp/vcluster-isv-validation.kubeconfig" \
  uv run isvctl test run -f ../ai-cloud-validation-provider/vcluster/config/k8s.yaml
```

From a checkout that contains the registry entry (`main` once
[NVIDIA/ai-cloud-validation#414](https://github.com/NVIDIA/ai-cloud-validation/pull/414)
merges, and releases after it), fetch the registered commit and run it by name
instead:

```bash
uv run isvctl provider fetch vcluster
uv run isvctl test run --provider vcluster --suite control-plane
uv run isvctl test run --provider vcluster --suite k8s   # with VCLUSTER_NODES, NGC_API_KEY and KUBECTL as above
```

Add `--phase setup|test|teardown` to run one phase of the `k8s` suite. Teardown
resets the worker nodes, so they can join a cluster again, deletes the tenant's
volume data and pod logs from them, and deletes the tenant.

### Reference environment

| | |
|---|---|
| Control plane cluster | GKE Standard, zonal, Kubernetes 1.36, 2x e2-standard-4, no GPUs |
| vCluster Platform | 4.12.5 on the control plane cluster, Free tier |
| vCluster | 0.37.6, tenant's cluster on Kubernetes 1.36.6 with a chart-deployed etcd |
| Worker nodes | 2x GCE g2-standard-8 (8 vCPU, 32 GB, 1x NVIDIA L4 24 GB), Ubuntu 24.04, kernel 7.0, 200 GB disk |
| In the tenant's cluster | Calico v3.32.3 (VXLAN), NVIDIA GPU Operator v26.7.2 (driver 595.91.07), NVIDIA DRA driver for GPUs 25.12.0, Kubeflow MPI Operator v0.5.0 |

### Preparing it on GCP

```bash
# Control plane cluster: hosts the Platform and the tenants' control planes
gcloud container clusters create <cluster> --zone <zone> --release-channel regular \
  --machine-type e2-standard-4 --num-nodes 2

# vCluster Platform (Free tier); activate it in its UI, then create an access key
vcluster platform start --email <you@example.com> --no-port-forwarding

# Worker nodes: one L4 each, reachable over SSH as a sudo user
ssh-keygen -t ed25519 -N '' -f node_key
gcloud compute instances create gpu-1 gpu-2 --zone <zone> \
  --machine-type g2-standard-8 --maintenance-policy TERMINATE \
  --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
  --boot-disk-size 200GB --metadata ssh-keys="ubuntu:$(cat node_key.pub)"
```

## Results

Against ai-cloud-validation v1.0.0 on the reference environment above, on
2026-10-31, at provider commit 782d857. Results were not uploaded
(`--no-upload`).

**`k8s`**, every check in one run, the NIM workloads and CNCF conformance
included:

| Result | Checks |
|---|---|
| Passed | NodeCount (2 nodes), NodeReady, NvidiaSmi (2 GPU nodes), DriverVersion (595.91.07 on both nodes), GpuPodAccess (1 GPU per node, 2 in total), GpuCapacity, GpuOperatorNamespace, GpuOperatorPods (19 pods), GpuOperatorOverride, GpuLabels, PodHealth, NoPendingPods, NoErrorPods, NetworkPolicy (allow, ingress-deny, egress-deny), CrdWebhook, Dra (an L4 allocated through a ResourceClaim), CncfConformance, NcclMultiNode (2 nodes, average bus bandwidth 0.45 GB/s), GpuStress (2 nodes), NimInference, NimHelm-1b (2.67 requests/s), NimHelm-3b (1.96 requests/s), ApiServerMetrics (452 metrics), ControlPlaneLogs (API server, scheduler, controller manager), ApiNetworkAcl |
| Reported passed, nothing tested | ExpectedNodes (no node names configured), NcclWorkload (needs 2 GPUs per node; these nodes have 1) |
| Failed | OidcIssuer (K8S17-02): the run did not set a public issuer; see [Known gaps](#known-gaps-against-the-100-suites) |
| Skipped | MigConfig (no MIG GPUs), DualStackNode (single-stack nodes), ClusterAutoscaler (none installed) |
| Not configured | The 17 checks whose steps are not wired; see Known gaps |

**CNCF conformance**: `certified-conformance` mode against the tenant's
cluster (Kubernetes v1.36.6): all 443 `[Conformance]` specs passed, none
skipped by the provider. vCluster's Private Nodes configuration is also
[CNCF-certified](https://github.com/cncf/k8s-conformance/tree/master/v1.36/vcluster-with-private-nodes)
for Kubernetes 1.36.

**`control-plane`**: all 10 checks passed at 65d0542, with direct access to
the control plane cluster. Since then only tenant creation and deletion changed
(`create_tenant.py`, `delete_tenant.py`). A run at 782d857 passed API health,
tenant creation and deletion, and access key creation and deletion. It reached
the control plane cluster through vCluster Platform, because the runner's cloud
session had expired. The Platform authenticates the suite's access key but
then needs it to have impersonation rights, so AccessKeyAuthenticated failed
with 403 and the four checks after it (access key disable and reject, tenant
list and info) did not run. `ObjectStorageCrudCheck` is not configured:
vCluster has no object storage API.

## How the provider runs the `k8s` suite

- **Tenant.** `setup.sh` logs in to vCluster Platform with a vcluster CLI config
  of its own and creates the tenant with `privateNodes.enabled` and
  `vcluster create --add`, which connects it to the Platform for its license.
  The Virtual Control Plane is backed by a chart-deployed etcd, as in vCluster's
  [CNCF-certified Private Nodes configuration](https://github.com/cncf/k8s-conformance/tree/master/v1.36/vcluster-with-private-nodes),
  and its API server is exposed through a LoadBalancer restricted to
  `VCLUSTER_API_ALLOWED_CIDRS`.
- **Network.** vCluster's default CNI, Flannel, does not enforce NetworkPolicy,
  so `setup.sh` turns it off and installs Calico with VXLAN encapsulation,
  which works on networks that drop IP-in-IP, GCP among them. kube-proxy and
  CoreDNS come from vCluster.
- **Nodes.** `setup.sh` creates a join token with `vcluster token create` and
  runs the join command it prints on each node over SSH; the node script
  installs containerd, kubelet and kube-proxy and joins the node through the
  LoadBalancer. vCluster reaches the nodes through Konnectivity, so the nodes
  need no inbound access from the control plane cluster.
- **Large images.** containerd cancels an image pull that makes no progress for
  5 minutes, and the next attempt downloads the image again. Cold pulls of the
  1.0.0 GPU stress image (`nvcr.io/nvidia/pytorch:26.08-py3`, 11 GB) stalled
  that long near the end of the download: in the reference run, twice on one
  node and once on the other before they succeeded. `config/k8s.yaml` gives
  the check 1200 s, which covers three attempts. If pulls keep failing on your
  nodes, raise `image_pull_progress_timeout` in their containerd configuration.
- **GPU Operator.** The tenant owns its GPU stack: `setup.sh` installs the NVIDIA
  GPU Operator in the tenant's cluster, driver included, and waits until every
  node advertises its GPUs. GPU Feature Discovery's labels give the suite its
  GPU counts and the driver version that `K8sDriverVersionCheck` compares.
- **DRA.** `setup.sh` installs the NVIDIA DRA driver for GPUs, which publishes
  the GPUs as `gpu.nvidia.com` devices next to the device plugin's
  `nvidia.com/gpu` resource. Its chart allows both on one node only with
  `gpuResourcesEnabledOverride`, because either can hand out a GPU the other
  already gave away. That cannot happen in this suite, which runs one GPU
  workload at a time. A production cluster keeps DRA and the device plugin on
  separate nodes, or runs DRA alone once DRAExtendedResource (KEP 5004) is GA.
  ComputeDomains (IMEX, for NVLink-connected nodes) stay off.
- **API network ACL.** The nodes reach the API server through the LoadBalancer,
  so they are on the allowlist, and a probe from inside the tenant's cluster
  would be allowed. `K8sApiNetworkAclCheck` therefore probes from a pod on the
  control plane cluster, whose egress address is outside the allowlist: that
  request must be blocked and kubectl from the runner must be served. The same
  pod must first reach the API server through its ClusterIP Service, so a pod
  without network access cannot pass as blocked. Any HTTP answer, a 401
  included, counts as reachable, and a probe that gets no result within its
  time limit fails the check. The source ranges do not cover the
  Service's ClusterIP and NodePort, so workloads inside the control plane
  cluster can still reach the API server, with credentials.
- **MPI Operator.** `setup.sh` installs the bundled Kubeflow MPI Operator
  v0.5.0 (`manifests/`) with server-side apply for the multi-node NCCL workload.
- **Teardown.** `teardown.sh` resets each node with the node script's
  `--reset-only` mode, deletes the tenant (which removes its LoadBalancer, its
  volumes and its record on the Platform), and removes the files `setup.sh`
  wrote. The reset leaves the tenant's data on the node, so teardown also
  deletes the volumes of the tenant's local-path StorageClass
  (`/opt/local-path-provisioner`) and the pod logs. containerd's image cache
  and the NVIDIA driver the GPU Operator loaded stay: reimage the nodes before
  another tenant gets them. Teardown reaches the control plane cluster through
  the context `setup.sh` used. `vcluster delete` reports a lookup that failed
  the same way as a deleted tenant, so teardown fails unless the cluster
  answers and the API shows none of the tenant's workloads or Services left.
- **Access keys** (`control-plane` suite). An access key is a ServiceAccount with
  a bound token. Disabling it removes its ClusterRoleBinding, so the token gets
  403. Deleting it removes both, and the `VCLUSTER_NAMESPACE` namespace too when
  `create_access_key.py` had to create it and nothing else lives there.

## Known gaps against the 1.0.0 suites

- **OIDC issuer (K8S17-02).** The check fetches the issuer's discovery document
  and signing keys anonymously from the runner, with normal TLS verification.
  By default the tenant's cluster issues tokens under its in-cluster issuer,
  which only the cluster can discover, so the check fails. Set
  `VCLUSTER_OIDC_ISSUER_URL` to a public HTTPS location, such as a public
  storage bucket, and `VCLUSTER_OIDC_PUBLISH_CMD` to a command that uploads the
  directory it is given there: `setup.sh` then issues tokens under that issuer
  and publishes both documents. The reference run did not set them.
- **Expected nodes.** `K8sExpectedNodesCheck` compares the nodes with a list of
  names from your bill of materials, which only you can supply: set its `names`.
  Without them the suite reports it as passed, "not configured".
- **Single-node NCCL and MIG.** `K8sNcclWorkload` needs at least two GPUs on one
  node and `K8sMigConfigCheck` needs MIG-capable GPUs; the reference nodes have
  one L4 each, so the first reports passed without running and the second skips.
- **Steps not wired.** Node pools, upgrades, control plane sizing, version
  listing, patching, service account IAM, the networking probes, `reset_gpus`
  and `cordon_node` need vCluster-specific implementations; their checks report
  `step_not_configured`. In the `control-plane` suite vCluster has no object
  storage API, so `ObjectStorageCrudCheck` reports `step_not_configured`.

## Layout

```text
config/       suite configs: k8s.yaml, control-plane.yaml
scripts/k8s/  setup.sh, teardown.sh, and _common.sh (inventory helper, vendored
              from ai-cloud-validation v1.0.0 isvctl/configs/providers/my-isv)
scripts/control-plane/  tenant and access key lifecycle; _platform.py logs the
              vcluster CLI in to vCluster Platform
manifests/    Kubeflow MPI Operator v0.5.0
```
