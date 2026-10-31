#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 vCluster Labs
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# shellcheck source-path=SCRIPTDIR

# vCluster K8s Setup - Creates a tenant (vCluster instance) with vCluster's
# Private Nodes tenancy model: its control plane runs on the control plane
# cluster, and dedicated worker nodes, joined over SSH, run its workloads. The
# tenant's cluster gets its own CNI (Calico) and NVIDIA GPU Operator, then the
# script emits the inventory JSON consumed by isvctl.
#
# Requirements:
#   - vcluster CLI matching VCLUSTER_VERSION (https://www.vcluster.com/docs/getting-started/setup)
#   - kubectl configured to point at the control plane cluster, which must be
#     able to publish a LoadBalancer Service the worker nodes can reach
#   - helm, jq, python3, curl, ssh
#   - a vCluster Platform and an access key for it: Private Nodes is a vCluster
#     Free tier feature, licensed through the Platform at no cost
#   - worker nodes reachable over SSH as a user with passwordless sudo, running
#     an OS vCluster supports for private nodes (Ubuntu 22.04 or 24.04, RHEL 8
#     to 10, Rocky, CentOS Stream) with their NVIDIA GPUs attached and no
#     Kubernetes installed. The NVIDIA driver comes from the GPU Operator.
#
# Environment variables:
#   VCLUSTER_PLATFORM_HOST       - vCluster Platform URL (required)
#   VCLUSTER_PLATFORM_ACCESS_KEY - access key for that Platform (required, or
#                                  VCLUSTER_PLATFORM_ACCESS_KEY_FILE)
#   VCLUSTER_PLATFORM_INSECURE   - "true" if the Platform's certificate is self-signed
#   VCLUSTER_NODES               - space-separated SSH destinations (user@host) of
#                                  the worker nodes (required)
#   VCLUSTER_NODE_SSH_KEY        - private key for those nodes (default: ssh's own)
#   VCLUSTER_NODE_SSH_OPTS       - extra ssh options, e.g. "-o UserKnownHostsFile=..."
#   VCLUSTER_VERSION             - vCluster chart version to deploy (default: 0.37.6)
#   VCLUSTER_NAME                - tenant's cluster name (default: acv-tenant)
#   VCLUSTER_NAMESPACE           - namespace on the control plane cluster
#                                  (default: vcluster-isv-validation)
#   VCLUSTER_KUBECONFIG_PATH     - where to write the tenant kubeconfig
#                                  (default: /tmp/vcluster-isv-validation.kubeconfig)
#   VCLUSTER_API_ALLOWED_CIDRS   - comma-separated CIDRs allowed to reach the
#                                  tenant's API LoadBalancer (default: this
#                                  machine's and each node's public IPv4 /32)
#   VCLUSTER_POD_CIDR            - tenant pod CIDR (default: 172.20.0.0/16)
#   VCLUSTER_SERVICE_CIDR        - tenant Service CIDR (default: 172.21.0.0/16)
#   CALICO_VERSION               - Calico release for the tenant's CNI (default: v3.32.3)
#   GPU_OPERATOR_VERSION         - NVIDIA GPU Operator release (default: v26.7.2)
#   DRA_DRIVER_VERSION           - NVIDIA DRA driver for GPUs chart (default: 25.12.0)
#   VCLUSTER_OIDC_ISSUER_URL     - public HTTPS URL to issue service account tokens
#                                  under (requirement K8S17-02). Unset keeps the
#                                  in-cluster issuer, which only the cluster can discover.
#   VCLUSTER_OIDC_PUBLISH_CMD    - command that publishes the directory passed as its
#                                  last argument (.well-known/openid-configuration and
#                                  openid/v1/jwks) at VCLUSTER_OIDC_ISSUER_URL
#   NGC_API_KEY                  - NGC token for nvcr.io pulls (NIM, hpc-benchmarks)
#
# Usage, from the root of an ai-cloud-validation checkout (see ../../README.md):
#   KUBECTL="kubectl --kubeconfig=/tmp/vcluster-isv-validation.kubeconfig" \
#     uv run isvctl test run --provider vcluster --suite k8s
#   Add --phase setup|test|teardown to run a single phase.

set -eo pipefail

# ---------------------------------------------------------------------------
# Tooling and inputs
# ---------------------------------------------------------------------------
for tool in vcluster kubectl helm jq python3 curl ssh; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' not found in PATH." >&2
        exit 1
    fi
done

VCLUSTER_VERSION="${VCLUSTER_VERSION:-0.37.6}"
VCLUSTER_NAME="${VCLUSTER_NAME:-acv-tenant}"
VCLUSTER_NAMESPACE="${VCLUSTER_NAMESPACE:-vcluster-isv-validation}"
VCLUSTER_KUBECONFIG_PATH="${VCLUSTER_KUBECONFIG_PATH:-/tmp/vcluster-isv-validation.kubeconfig}"
VCLUSTER_POD_CIDR="${VCLUSTER_POD_CIDR:-172.20.0.0/16}"
VCLUSTER_SERVICE_CIDR="${VCLUSTER_SERVICE_CIDR:-172.21.0.0/16}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.3}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.2}"
DRA_DRIVER_VERSION="${DRA_DRIVER_VERSION:-25.12.0}"
VCLUSTER_OIDC_ISSUER_URL="${VCLUSTER_OIDC_ISSUER_URL%/}"
if [ -n "$VCLUSTER_OIDC_ISSUER_URL" ] && [ -z "${VCLUSTER_OIDC_PUBLISH_CMD:-}" ]; then
    echo "Error: VCLUSTER_OIDC_ISSUER_URL needs VCLUSTER_OIDC_PUBLISH_CMD to publish the issuer's documents." >&2
    exit 1
fi
if [ -z "${VCLUSTER_PLATFORM_ACCESS_KEY:-}" ] && [ -n "${VCLUSTER_PLATFORM_ACCESS_KEY_FILE:-}" ]; then
    VCLUSTER_PLATFORM_ACCESS_KEY=$(tr -d '[:space:]' < "$VCLUSTER_PLATFORM_ACCESS_KEY_FILE")
fi
if [ -z "${VCLUSTER_PLATFORM_HOST:-}" ] || [ -z "${VCLUSTER_PLATFORM_ACCESS_KEY:-}" ]; then
    echo "Error: set VCLUSTER_PLATFORM_HOST and VCLUSTER_PLATFORM_ACCESS_KEY (Private Nodes is licensed through vCluster Platform)." >&2
    exit 1
fi
read -r -a NODES <<<"${VCLUSTER_NODES:-}"
if [ "${#NODES[@]}" -eq 0 ]; then
    echo "Error: set VCLUSTER_NODES to the SSH destinations of the worker nodes." >&2
    exit 1
fi

# The control plane cluster's kubeconfig, saved before KUBECONFIG switches to the tenant.
HOST_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
HOST_CONTEXT=$(kubectl --kubeconfig="$HOST_KUBECONFIG" config current-context)
# Files this script keeps next to the tenant's kubeconfig; teardown.sh removes them.
STATE_PREFIX="${VCLUSTER_KUBECONFIG_PATH%.kubeconfig}"
VCLUSTER_CLI_CONFIG="${STATE_PREFIX}-cli.json"
VALUES_FILE="${STATE_PREFIX}-values.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The vcluster CLI keeps its Platform login in its own config, never ~/.vcluster.
vc() { vcluster --config "$VCLUSTER_CLI_CONFIG" "$@"; }
# Calls to the control plane cluster use the context saved above, even if the
# current context changes during the run; teardown.sh reads it back from here.
HOST_CONTEXT_FILE="${STATE_PREFIX}-host-context"
vc_host() { vc --context "$HOST_CONTEXT" "$@"; }
host_kubectl() { kubectl --kubeconfig="$HOST_KUBECONFIG" --context="$HOST_CONTEXT" "$@"; }
# User options first: ssh keeps the first value it gets for each option.
SSH_CMD=(ssh)
# shellcheck disable=SC2206 # options are meant to split into words
[ -n "${VCLUSTER_NODE_SSH_OPTS:-}" ] && SSH_CMD+=(${VCLUSTER_NODE_SSH_OPTS})
SSH_CMD+=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
[ -n "${VCLUSTER_NODE_SSH_KEY:-}" ] && SSH_CMD+=(-i "$VCLUSTER_NODE_SSH_KEY" -o IdentitiesOnly=yes)
node_ssh() { local dest="$1"; shift; "${SSH_CMD[@]}" "$dest" "$@"; }

# ---------------------------------------------------------------------------
# Log in to vCluster Platform. vcluster create --add then connects the tenant
# to it, which licenses Private Nodes.
# ---------------------------------------------------------------------------
LOGIN_ARGS=(--access-key "$VCLUSTER_PLATFORM_ACCESS_KEY" --docker-login=false)
[ "${VCLUSTER_PLATFORM_INSECURE:-false}" = "true" ] && LOGIN_ARGS+=(--insecure)
(
    umask 077
    vc platform login "$VCLUSTER_PLATFORM_HOST" "${LOGIN_ARGS[@]}" >/dev/null
)
echo "Logged in to vCluster Platform ${VCLUSTER_PLATFORM_HOST}." >&2

# ---------------------------------------------------------------------------
# API endpoint allowlist (requirement K8S15: the cluster endpoint must provide
# network access controls). Worker nodes join and talk to the API server
# through the tenant's LoadBalancer, so it admits this machine and the nodes'
# public egress addresses, and nothing else unless VCLUSTER_API_ALLOWED_CIDRS
# says so.
# ---------------------------------------------------------------------------
public_ipv4() { curl -4 -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]'; }
if [ -z "${VCLUSTER_API_ALLOWED_CIDRS:-}" ]; then
    _CIDRS=""
    for _src in runner "${NODES[@]}"; do
        if [ "$_src" = "runner" ]; then
            _IP=$(public_ipv4 || true)
        else
            _IP=$(node_ssh "$_src" 'curl -4 -fsS --max-time 10 https://checkip.amazonaws.com' 2>/dev/null | tr -d '[:space:]' || true)
        fi
        if ! [[ "$_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: could not detect the public IPv4 address of ${_src}; set VCLUSTER_API_ALLOWED_CIDRS." >&2
            exit 1
        fi
        _CIDRS="${_CIDRS},${_IP}/32"
    done
    VCLUSTER_API_ALLOWED_CIDRS="$_CIDRS"
fi
# Normalize the list: no spaces, no empty entries, no duplicates.
VCLUSTER_API_ALLOWED_CIDRS=$(python3 -c '
import sys
seen = []
for c in sys.argv[1].split(","):
    c = c.strip()
    if c and c not in seen:
        seen.append(c)
print(",".join(seen))' "$VCLUSTER_API_ALLOWED_CIDRS")
echo "API LoadBalancer allowlist: ${VCLUSTER_API_ALLOWED_CIDRS}" >&2

# ---------------------------------------------------------------------------
# Create the tenant (skip if it already exists)
# ---------------------------------------------------------------------------
python3 - "$VALUES_FILE" "$VCLUSTER_API_ALLOWED_CIDRS" "$VCLUSTER_POD_CIDR" "$VCLUSTER_SERVICE_CIDR" "$VCLUSTER_OIDC_ISSUER_URL" <<'PYEOF'
import json, sys
path, cidrs, pod_cidr, service_cidr, oidc_issuer = sys.argv[1:6]
values = {
    # Dedicated worker nodes join the tenant's cluster; no workload runs on,
    # or is synced to, the control plane cluster.
    "privateNodes": {"enabled": True},
    "controlPlane": {
        # A real etcd, as in vCluster's CNCF-certified Private Nodes
        # configuration (cncf/k8s-conformance v1.36/vcluster-with-private-nodes).
        "backingStore": {"etcd": {"deploy": {"enabled": True}}},
        "service": {"spec": {"type": "LoadBalancer", "loadBalancerSourceRanges": cidrs.split(",")}},
        # Headroom for CNCF conformance, which creates hundreds of namespaces.
        "statefulSet": {"resources": {"requests": {"cpu": "500m", "memory": "512Mi"}}},
    },
    "networking": {"podCIDR": pod_cidr, "serviceCIDR": service_cidr},
    # Calico replaces the default Flannel: Flannel does not enforce NetworkPolicy.
    "deploy": {"cni": {"flannel": {"enabled": False}}},
}
if oidc_issuer:
    # Tokens are issued under the public issuer (the first value); the default
    # in-cluster issuer stays accepted. vCluster drops its own issuer flag when
    # extraArgs set one.
    api_server_args = [
        "--service-account-issuer=" + oidc_issuer,
        "--service-account-issuer=https://kubernetes.default.svc.cluster.local",
        "--service-account-jwks-uri=" + oidc_issuer + "/openid/v1/jwks",
    ]
else:
    # Issuer discovery advertises the in-cluster API address, as in the
    # CNCF-certified Private Nodes configuration.
    api_server_args = ["--service-account-jwks-uri=https://kubernetes.default.svc.cluster.local/openid/v1/jwks"]
values["controlPlane"]["distro"] = {"k8s": {"apiServer": {"extraArgs": api_server_args}}}
with open(path, "w") as f:
    json.dump(values, f, indent=2)
PYEOF
printf '%s\n' "$HOST_CONTEXT" > "$HOST_CONTEXT_FILE"

tenant_status() {
    vc_host list --driver helm --namespace "$VCLUSTER_NAMESPACE" --output json 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin) or []
match = next((v for v in items if v.get('Name') == sys.argv[1]), None)
print(match['Status'] if match else '')
" "$VCLUSTER_NAME" 2>/dev/null || echo ""
}

EXISTING_STATUS=$(tenant_status)
if [ -z "$EXISTING_STATUS" ]; then
    echo "Creating vCluster '${VCLUSTER_NAME}' (chart ${VCLUSTER_VERSION}, Private Nodes) in namespace '${VCLUSTER_NAMESPACE}'..." >&2
    # --expose puts the LoadBalancer address in the API server certificate, so
    # nodes and kubeconfigs can use it; --add connects the tenant to the Platform.
    vc_host create "$VCLUSTER_NAME" --driver helm --namespace "$VCLUSTER_NAMESPACE" \
        --chart-version "$VCLUSTER_VERSION" --connect=false --add --expose \
        -f "$VALUES_FILE" >&2
else
    echo "vCluster '${VCLUSTER_NAME}' already exists (status: ${EXISTING_STATUS}), reusing." >&2
    # A reused tenant keeps the allowlist it was created with: apply the current one.
    _RANGES_JSON=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1].split(",")))' "$VCLUSTER_API_ALLOWED_CIDRS")
    host_kubectl -n "$VCLUSTER_NAMESPACE" patch svc "$VCLUSTER_NAME" \
        --type merge -p "{\"spec\":{\"loadBalancerSourceRanges\":${_RANGES_JSON}}}" >/dev/null
fi

echo "Waiting for vCluster to reach Running status..." >&2
for i in $(seq 1 60); do
    STATUS=$(tenant_status)
    [ "$STATUS" = "Running" ] && { echo "vCluster is Running." >&2; break; }
    [ "$i" -eq 60 ] && { echo "Error: vCluster did not reach Running status within 5 minutes (status: ${STATUS:-none})." >&2; exit 1; }
    sleep 5
done

# ---------------------------------------------------------------------------
# Connect and persist the tenant's kubeconfig (server: the LoadBalancer).
# ---------------------------------------------------------------------------
echo "Connecting to vCluster, saving kubeconfig to ${VCLUSTER_KUBECONFIG_PATH}..." >&2
# The kubeconfig holds the tenant's admin credentials: owner-only permissions.
(
    umask 077
    vc_host connect "$VCLUSTER_NAME" --driver helm --namespace "$VCLUSTER_NAMESPACE" --print \
        2>/dev/null > "$VCLUSTER_KUBECONFIG_PATH"
)
chmod 600 "$VCLUSTER_KUBECONFIG_PATH"
export KUBECONFIG="$VCLUSTER_KUBECONFIG_PATH"
KUBECTL="kubectl"

# Cloud load balancers can take 1-3 minutes to pass health checks.
echo "Waiting for the tenant's API to become reachable..." >&2
for i in $(seq 1 36); do
    $KUBECTL cluster-info &>/dev/null && break
    [ "$i" -eq 36 ] && { echo "Error: cannot reach the tenant's API via ${VCLUSTER_KUBECONFIG_PATH} after 3 minutes." >&2; exit 1; }
    sleep 5
done
echo "Connected to the tenant's cluster." >&2

# ---------------------------------------------------------------------------
# Publish the service account issuer (requirement K8S17-02). The API server
# serves its discovery document and signing keys to authenticated callers
# only; copies at the public issuer URL let anyone outside the cluster verify
# the tenant's tokens, as workload identity federation needs.
# ---------------------------------------------------------------------------
if [ -n "$VCLUSTER_OIDC_ISSUER_URL" ]; then
    OIDC_DIR="${STATE_PREFIX}-oidc"
    rm -rf "$OIDC_DIR"
    mkdir -p "$OIDC_DIR/.well-known" "$OIDC_DIR/openid/v1"
    $KUBECTL get --raw /.well-known/openid-configuration > "$OIDC_DIR/.well-known/openid-configuration"
    $KUBECTL get --raw /openid/v1/jwks > "$OIDC_DIR/openid/v1/jwks"
    _ISSUER=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["issuer"])' "$OIDC_DIR/.well-known/openid-configuration")
    if [ "$_ISSUER" != "$VCLUSTER_OIDC_ISSUER_URL" ]; then
        echo "Error: the tenant's API server reports issuer ${_ISSUER}, not ${VCLUSTER_OIDC_ISSUER_URL} (a reused tenant keeps the issuer it was created with)." >&2
        exit 1
    fi
    echo "Publishing the service account issuer at ${VCLUSTER_OIDC_ISSUER_URL}..." >&2
    # shellcheck disable=SC2086 # the command is meant to split into words
    $VCLUSTER_OIDC_PUBLISH_CMD "$OIDC_DIR" >&2
fi

# ---------------------------------------------------------------------------
# Calico, the tenant's CNI. VXLAN encapsulation works on networks that drop
# IP-in-IP (GCP among them).
# ---------------------------------------------------------------------------
echo "Installing Calico ${CALICO_VERSION} in the tenant's cluster..." >&2
# Since v3.32 the CRDs ship in their own chart; server-side apply because some
# exceed the client-side apply size limit.
helm template calico-crds crd.projectcalico.org.v1 --repo https://docs.tigera.io/calico/charts \
    --version "$CALICO_VERSION" | $KUBECTL apply --server-side --force-conflicts -f - >/dev/null
helm upgrade --install calico tigera-operator --repo https://docs.tigera.io/calico/charts \
    --version "$CALICO_VERSION" --namespace tigera-operator --create-namespace \
    -f - >/dev/null <<EOF
installation:
  cni:
    type: Calico
  calicoNetwork:
    bgp: Disabled
    ipPools:
      - cidr: ${VCLUSTER_POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
EOF

# ---------------------------------------------------------------------------
# Join the worker nodes. vcluster token create prints a one-line join command
# (it carries a bootstrap token that expires in an hour); each node runs it as
# root, which installs containerd, kubelet and kube-proxy and joins the node.
# ---------------------------------------------------------------------------
JOIN_CMD=""
for node in "${NODES[@]}"; do
    # Node names are the lowercased hostname.
    NODE_NAME=$(node_ssh "$node" hostname | tr '[:upper:]' '[:lower:]')
    if $KUBECTL get node "$NODE_NAME" &>/dev/null; then
        echo "Node ${NODE_NAME} already joined." >&2
        continue
    fi
    if [ -z "$JOIN_CMD" ]; then
        JOIN_CMD=$(vc token create --expires 1h 2>/dev/null | grep -E 'curl .*/node/join' | tail -1)
        [ -z "$JOIN_CMD" ] && { echo "Error: vcluster token create returned no join command." >&2; exit 1; }
    fi
    echo "Joining ${NODE_NAME} (${node})..." >&2
    # The command goes over stdin so the token never appears in a process list.
    # It is "curl ... | sh -": pipefail makes a failed download fail the join.
    if ! node_ssh "$node" 'sudo bash -o pipefail -s' <<<"$JOIN_CMD" >&2; then
        echo "Error: joining ${node} failed." >&2
        exit 1
    fi
done

echo "Waiting for ${#NODES[@]} node(s) to become Ready..." >&2
for i in $(seq 1 60); do
    READY=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ') || READY=0
    [ "$READY" -ge "${#NODES[@]}" ] && { echo "${READY} node(s) Ready." >&2; break; }
    [ "$i" -eq 60 ] && { echo "Error: only ${READY} of ${#NODES[@]} node(s) Ready after 10 minutes." >&2; $KUBECTL get nodes >&2 || true; exit 1; }
    sleep 10
done

# ---------------------------------------------------------------------------
# NVIDIA GPU Operator, owned by the tenant: it installs the driver, container
# toolkit, device plugin, GPU Feature Discovery and DCGM exporter on the
# tenant's nodes (requirement K8S25).
# ---------------------------------------------------------------------------
echo "Installing NVIDIA GPU Operator ${GPU_OPERATOR_VERSION} in the tenant's cluster..." >&2
$KUBECTL create namespace gpu-operator --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL label namespace gpu-operator pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
helm upgrade --install gpu-operator gpu-operator --repo https://helm.ngc.nvidia.com/nvidia \
    --version "$GPU_OPERATOR_VERSION" --namespace gpu-operator >/dev/null

# The driver container builds the kernel module on each node, which takes a
# few minutes; wait until every node advertises its GPUs.
echo "Waiting for the GPUs to be allocatable (driver build included)..." >&2
for i in $(seq 1 90); do
    GPU_NODES=$($KUBECTL get nodes -o json 2>/dev/null | python3 -c '
import json, sys
nodes = json.load(sys.stdin)["items"]
print(sum(1 for n in nodes if int(n["status"].get("allocatable", {}).get("nvidia.com/gpu", "0") or 0) > 0))' 2>/dev/null) || GPU_NODES=0
    [ "$GPU_NODES" -ge "${#NODES[@]}" ] && { echo "GPUs allocatable on ${GPU_NODES} node(s)." >&2; break; }
    [ "$i" -eq 90 ] && { echo "Error: GPUs allocatable on ${GPU_NODES} of ${#NODES[@]} node(s) after 30 minutes." >&2; $KUBECTL get pods -n gpu-operator >&2 || true; exit 1; }
    sleep 20
done

# ---------------------------------------------------------------------------
# NVIDIA DRA driver for GPUs (requirement K8S24): publishes the GPUs as DRA
# devices (DeviceClass gpu.nvidia.com) next to the device plugin's
# nvidia.com/gpu resource. Its chart allows both on one node only with
# gpuResourcesEnabledOverride, because either can hand out a GPU the other
# already gave away. That cannot happen in this suite, which runs one GPU
# workload at a time; a production cluster keeps DRA and the device plugin on
# separate nodes, or runs DRA alone once DRAExtendedResource (KEP 5004) is GA.
# ComputeDomains (IMEX, for NVLink-connected nodes) stay off.
# ---------------------------------------------------------------------------
echo "Installing NVIDIA DRA driver ${DRA_DRIVER_VERSION} in the tenant's cluster..." >&2
if helm upgrade --install nvidia-dra-driver-gpu nvidia-dra-driver-gpu --repo https://helm.ngc.nvidia.com/nvidia \
        --version "$DRA_DRIVER_VERSION" --namespace nvidia-dra-driver-gpu --create-namespace \
        --set nvidiaDriverRoot=/run/nvidia/driver \
        --set resources.computeDomains.enabled=false \
        --set gpuResourcesEnabledOverride=true >/dev/null; then
    for i in $(seq 1 30); do
        DRA_NODES=$($KUBECTL get resourceslices -o json 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
print(len({s["spec"].get("nodeName") for s in items if s["spec"].get("driver") == "gpu.nvidia.com"}))' 2>/dev/null || echo 0)
        [ "$DRA_NODES" -ge "${#NODES[@]}" ] && { echo "GPUs published as DRA devices on ${DRA_NODES} node(s)." >&2; break; }
        [ "$i" -eq 30 ] && echo "  Warning: DRA devices on ${DRA_NODES} of ${#NODES[@]} node(s) after 5 minutes." >&2
        sleep 10
    done
else
    echo "  Warning: DRA driver install failed (K8sDraCheck will fail)." >&2
fi

# ---------------------------------------------------------------------------
# Kubeflow MPI Operator, for K8sNcclMultiNodeWorkload's MPIJobs. The manifest
# is bundled in the provider directory to avoid runtime fetches.
# ---------------------------------------------------------------------------
MPI_OPERATOR_MANIFEST="${SCRIPT_DIR}/../../manifests/mpi-operator-v0.5.0.yaml"
echo "Installing Kubeflow MPI Operator in the tenant's cluster..." >&2
# Server-side apply: the MPIJob CRD is too large for the last-applied annotation.
if $KUBECTL apply --server-side --force-conflicts -f "$MPI_OPERATOR_MANIFEST" >/dev/null 2>&1; then
    echo "  MPI Operator installed." >&2
else
    echo "  Warning: MPI Operator install failed (multi-node NCCL will skip)." >&2
fi

# ---------------------------------------------------------------------------
# NGC image pull secret in the default namespace, for nvcr.io images such as
# hpc-benchmarks; the default ServiceAccount injects it into every pod.
# ---------------------------------------------------------------------------
if [ -n "${NGC_API_KEY:-}" ]; then
    echo "Creating NGC image pull secret in the default namespace..." >&2
    # The key reaches python on stdin, never a command line, where ps would show it.
    printf '%s' "$NGC_API_KEY" | python3 -c '
import base64, json, sys
key = sys.stdin.read()
auth = base64.b64encode(("$oauthtoken:" + key).encode()).decode()
config = {"auths": {"nvcr.io": {"username": "$oauthtoken", "password": key, "auth": auth}}}
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "type": "kubernetes.io/dockerconfigjson",
    "metadata": {"name": "ngc-hpc-pull-secret", "namespace": "default"},
    "data": {".dockerconfigjson": base64.b64encode(json.dumps(config).encode()).decode()},
}))' 2>/dev/null \
        | $KUBECTL apply -f - >/dev/null 2>&1 \
        && $KUBECTL patch serviceaccount default -n default \
            -p '{"imagePullSecrets": [{"name": "ngc-hpc-pull-secret"}]}' >/dev/null 2>&1 \
        && echo "  NGC pull secret created." >&2 \
        || echo "  Warning: NGC pull secret setup failed." >&2
fi

# ---------------------------------------------------------------------------
# API network ACL (K8sApiNetworkAclCheck, requirement K8S15).
#
# The nodes are on the allowlist, so the probe cannot run in the tenant's own
# cluster. It runs from a pod on the control plane cluster instead, whose
# egress address is outside the allowlist, and must be blocked. Any HTTP
# answer, a 401 included, counts as reachable, so an authentication error can
# never pass for a network ACL. The pod first reaches the API server through
# its ClusterIP Service, which the source ranges do not cover, so a pod with no
# network at all cannot pass as blocked. The probe bounds its own run time well
# inside the check's probe_timeout_s and exits 127 on any failure of its own.
# ---------------------------------------------------------------------------
ACL_PROBE="${VCLUSTER_KUBECONFIG_PATH}.acl-probe.sh"
rm -f "$ACL_PROBE"
# Clouds publish an IP (GKE, AKS) or a hostname (AWS load balancers).
_ACL_LB=$(host_kubectl get svc "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$_ACL_LB" ]; then
    echo "Tenant API LoadBalancer: ${_ACL_LB}" >&2
    (
        umask 077
        {
            echo '#!/usr/bin/env bash'
            echo '# Unauthorized probe for K8sApiNetworkAclCheck, written by setup.sh. Connects to'
            echo "# the tenant's API LoadBalancer from a pod on the control plane cluster, whose"
            echo '# egress address is outside the allowlist.'
            echo '# Exit 0: reachable (no ACL). Exit 1: blocked. Exit 127: the probe itself failed.'
            printf 'LB=%q\n' "$_ACL_LB"
            printf 'SVC=%q\n' "${VCLUSTER_NAME}.${VCLUSTER_NAMESPACE}.svc"
            printf 'K=(kubectl --kubeconfig=%q --context=%q -n %q)\n' "$HOST_KUBECONFIG" "$HOST_CONTEXT" "$VCLUSTER_NAMESPACE"
            cat <<'PROBEEOF'
POD="acl-probe-$$"
if ! "${K[@]}" run "$POD" --restart=Never --image=curlimages/curl:8.11.1 --request-timeout=15s --command -- \
        sh -c "curl -sk --max-time 10 -o /dev/null -w 'svc_http=%{http_code}' https://${SVC}/readyz; echo \" svc_rc=\$?\"; curl -sk --max-time 10 -o /dev/null -w 'http=%{http_code}' https://${LB}/readyz; echo \" rc=\$?\"" >/dev/null 2>&1; then
    echo "probe failed: could not create pod ${POD}"; exit 127
fi
OUT=""
if "${K[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" --timeout=60s >/dev/null 2>&1; then
    OUT=$("${K[@]}" logs "$POD" --request-timeout=10s 2>/dev/null)
fi
"${K[@]}" delete pod "$POD" --ignore-not-found --wait=false --request-timeout=10s >/dev/null 2>&1
case "$OUT" in
    *" svc_rc=0"*) ;;
    *) echo "probe failed: the pod did not reach the API server's ClusterIP Service either: ${OUT:-no result within the time limit}"; exit 127 ;;
esac
case "$OUT" in
    *" rc=0"*) echo "reachable from the control plane cluster: ${OUT}"; exit 0 ;;
    *" rc=7"* | *" rc=28"*) echo "blocked from the control plane cluster: ${OUT}"; exit 1 ;;
    *) echo "probe failed: ${OUT:-no result within the time limit}"; exit 127 ;;
esac
PROBEEOF
        } > "$ACL_PROBE"
    )
    chmod 700 "$ACL_PROBE"
else
    echo "  Warning: LoadBalancer address not available; K8sApiNetworkAclCheck will fail." >&2
fi

# ---------------------------------------------------------------------------
# Output cluster inventory (sources shared _common.sh logic)
# ---------------------------------------------------------------------------
CLUSTER_NAME=$($KUBECTL config current-context 2>/dev/null || echo "$VCLUSTER_NAME")
DEFAULT_GPU_NS="gpu-operator"
REQUIRE_JQ="true"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"
