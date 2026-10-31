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

# vCluster K8s Teardown - Resets the worker nodes setup.sh joined, so they can
# join a cluster again, deletes the tenant (vCluster instance), and removes the
# files setup.sh wrote.
#
# Environment variables (as for setup.sh):
#   VCLUSTER_NAME             - name of the tenant's cluster (default: acv-tenant)
#   VCLUSTER_NAMESPACE        - namespace on the control plane cluster (default: vcluster-isv-validation)
#   VCLUSTER_KUBECONFIG_PATH  - the tenant kubeconfig setup.sh wrote (default: /tmp/vcluster-isv-validation.kubeconfig)
#   VCLUSTER_NODES            - SSH destinations of the worker nodes (optional: without
#                               it the nodes keep their Kubernetes components)
#   VCLUSTER_NODE_SSH_KEY, VCLUSTER_NODE_SSH_OPTS - as for setup.sh

set -eo pipefail

VCLUSTER_NAME="${VCLUSTER_NAME:-acv-tenant}"
VCLUSTER_NAMESPACE="${VCLUSTER_NAMESPACE:-vcluster-isv-validation}"
VCLUSTER_KUBECONFIG_PATH="${VCLUSTER_KUBECONFIG_PATH:-/tmp/vcluster-isv-validation.kubeconfig}"
STATE_PREFIX="${VCLUSTER_KUBECONFIG_PATH%.kubeconfig}"
VCLUSTER_CLI_CONFIG="${STATE_PREFIX}-cli.json"
read -r -a NODES <<<"${VCLUSTER_NODES:-}"

vc() { vcluster --config "$VCLUSTER_CLI_CONFIG" "$@"; }
# The control plane cluster's context that setup.sh used, so teardown reaches
# the same cluster even if the current context changed during the run.
HOST_CONTEXT_FILE="${STATE_PREFIX}-host-context"
HOST_CONTEXT=$(cat "$HOST_CONTEXT_FILE" 2>/dev/null || true)
HOST_CTX_ARGS=()
[ -n "$HOST_CONTEXT" ] && HOST_CTX_ARGS=(--context "$HOST_CONTEXT")
# User options first: ssh keeps the first value it gets for each option.
SSH_CMD=(ssh)
# shellcheck disable=SC2206 # options are meant to split into words
[ -n "${VCLUSTER_NODE_SSH_OPTS:-}" ] && SSH_CMD+=(${VCLUSTER_NODE_SSH_OPTS})
SSH_CMD+=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
[ -n "${VCLUSTER_NODE_SSH_KEY:-}" ] && SSH_CMD+=(-i "$VCLUSTER_NODE_SSH_KEY" -o IdentitiesOnly=yes)

# ---------------------------------------------------------------------------
# Reset the worker nodes while the tenant still serves the node script: its
# --reset-only mode removes kubelet, containerd and the other node components.
# It leaves the tenant's data behind, so a reset node also loses the volumes of
# the tenant's local-path StorageClass and the pod logs. containerd's image
# cache and the NVIDIA driver the GPU Operator loaded stay on the node.
# Best effort: a node that is gone or unreachable is reported and skipped.
# ---------------------------------------------------------------------------
NODE_DATA_DIRS="/opt/local-path-provisioner /var/log/pods /var/log/containers"
if [ "${#NODES[@]}" -gt 0 ] && [ -f "$VCLUSTER_KUBECONFIG_PATH" ]; then
    JOIN_CMD=$(KUBECONFIG="$VCLUSTER_KUBECONFIG_PATH" vc token create --expires 1h 2>/dev/null | grep -E 'curl .*/node/join' | tail -1 || true)
    if [ -n "$JOIN_CMD" ]; then
        RESET_CMD="${JOIN_CMD% -} -s -- --reset-only"
        for node in "${NODES[@]}"; do
            echo "Resetting node ${node}..." >&2
            # "curl ... | sh -s": pipefail makes a failed download fail the reset.
            # The data goes only after a reset, when no pod uses it any more.
            if "${SSH_CMD[@]}" "$node" 'sudo bash -o pipefail -s' <<<"$RESET_CMD" >/dev/null 2>&1 &&
                "${SSH_CMD[@]}" "$node" "sudo rm -rf ${NODE_DATA_DIRS}" >/dev/null 2>&1; then
                echo "  ${node} reset." >&2
            else
                echo "  Warning: could not reset ${node}; it may still hold the tenant's data." >&2
            fi
        done
    else
        echo "Warning: the tenant did not issue a node token; nodes were not reset." >&2
    fi
fi

# ---------------------------------------------------------------------------
# Delete the tenant. Uses the ambient KUBECONFIG (control plane cluster).
# vcluster delete reports a lookup that failed (expired credentials, no
# permission) as "couldn't find vcluster", like a tenant that is gone, so an
# unreachable cluster fails the teardown here, and the API confirms below that
# nothing of the tenant is left.
# ---------------------------------------------------------------------------
if ! kubectl "${HOST_CTX_ARGS[@]}" get --raw /version >/dev/null 2>&1; then
    echo "Error: cannot reach the control plane cluster with the current KUBECONFIG; the tenant was not deleted." >&2
    exit 1
fi
echo "Deleting vCluster '${VCLUSTER_NAME}' from namespace '${VCLUSTER_NAMESPACE}'..." >&2
DELETE_RC=0
DELETE_OUT=$(vc "${HOST_CTX_ARGS[@]}" delete "$VCLUSTER_NAME" --driver helm --namespace "$VCLUSTER_NAMESPACE" 2>&1) || DELETE_RC=$?
if [ "$DELETE_RC" -ne 0 ] && ! echo "$DELETE_OUT" | grep -qi "not found\|does not exist\|couldn't find"; then
    echo "Error: vcluster delete failed (exit ${DELETE_RC}):" >&2
    echo "$DELETE_OUT" >&2
    exit 1
fi
for i in $(seq 1 24); do
    if ! LEFT=$(kubectl "${HOST_CTX_ARGS[@]}" get statefulsets,deployments,services -n "$VCLUSTER_NAMESPACE" \
            -l "release=${VCLUSTER_NAME}" -o name 2>/dev/null); then
        echo "Error: could not confirm that vCluster '${VCLUSTER_NAME}' is gone (kubectl get failed)." >&2
        exit 1
    fi
    [ -z "$LEFT" ] && break
    [ "$i" -eq 24 ] && { echo "Error: vCluster '${VCLUSTER_NAME}' still has resources after 2 minutes:" >&2; echo "$LEFT" >&2; exit 1; }
    sleep 5
done
if [ "$DELETE_RC" -eq 0 ]; then
    echo "vCluster deleted." >&2
else
    echo "vCluster '${VCLUSTER_NAME}' was already absent; nothing to do." >&2
fi

# ---------------------------------------------------------------------------
# Remove the files setup.sh wrote: the tenant's kubeconfig, its values, the
# ACL probe, the issuer documents, and the vcluster CLI config holding the
# Platform login. Documents published at VCLUSTER_OIDC_ISSUER_URL stay where
# VCLUSTER_OIDC_PUBLISH_CMD put them.
# ---------------------------------------------------------------------------
rm -f "$VCLUSTER_KUBECONFIG_PATH" "${VCLUSTER_KUBECONFIG_PATH}.acl-probe.sh" \
    "${STATE_PREFIX}-values.yaml" "$VCLUSTER_CLI_CONFIG" "$HOST_CONTEXT_FILE"
rm -rf "${STATE_PREFIX}-oidc"
echo "Teardown complete." >&2
