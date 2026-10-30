#!/usr/bin/env python3
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

"""Delete a ServiceAccount (and any associated token secrets) from the cluster.

Teardown counterpart to create_access_key.py. Removes the ServiceAccount from
the vCluster namespace on the control plane cluster, and the namespace itself
when create_access_key.py created it and it is otherwise empty. Kubernetes
garbage-collects all secrets owned by the SA automatically.

Required JSON output:
{
    "success":           bool - true if the SA was deleted (or was already gone),
    "platform":          str  - "control_plane",
    "resources_deleted": list - deleted resource names,
    "message":           str  - human-readable result summary,
    "error":             str  - (optional) present when success is false
}

Usage:
    python delete_access_key.py --username <sa-name> \
        --access-key-id <sa-name> --region vcluster
"""

import argparse
import json
import os
import subprocess
import sys
from typing import Any

DEMO_MODE = os.environ.get("ISVCTL_DEMO_MODE") == "1"

# Set by create_access_key.py on a namespace it had to create.
CREATED_BY_LABEL = "ai-cloud-validation/created-by=create_access_key"


def _kubeconfig_env() -> dict[str, str]:
    env = os.environ.copy()
    host_kc = env.get("VCLUSTER_HOST_KUBECONFIG") or env.get("KUBECONFIG", "")
    if host_kc:
        env["KUBECONFIG"] = host_kc
    return env


def _run(cmd: list[str], env: dict[str, str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Delete vCluster ServiceAccount")
    parser.add_argument("--username", required=True, help="ServiceAccount name")
    parser.add_argument("--access-key-id", required=True, help="ServiceAccount name")
    parser.add_argument("--region", required=True, help="Region label (use 'vcluster')")
    args = parser.parse_args()

    ns = os.environ.get("VCLUSTER_NAMESPACE", "vcluster-isv-validation")

    result: dict[str, Any] = {
        "success": False,
        "platform": "control_plane",
        "resources_deleted": [],
        "message": "",
    }

    if DEMO_MODE:
        result["resources_deleted"] = [args.username]
        result["message"] = f"ServiceAccount '{args.username}' deleted (demo)"
        result["success"] = True
        print(json.dumps(result, indent=2))
        return 0

    try:
        env = _kubeconfig_env()

        rc, _, stderr = _run(
            ["kubectl", "delete", "serviceaccount", args.username, "-n", ns, "--ignore-not-found=true"],
            env,
        )

        if rc != 0:
            result["error"] = f"Failed to delete ServiceAccount: {stderr}"
            print(json.dumps(result, indent=2))
            return 1

        # Clean up the ClusterRoleBinding created by create_access_key.py
        crb_name = f"{args.username}-view"
        rc_crb, _, stderr_crb = _run(
            ["kubectl", "delete", "clusterrolebinding", crb_name, "--ignore-not-found=true"],
            env,
        )
        if rc_crb != 0:
            result["error"] = f"Failed to delete ClusterRoleBinding '{crb_name}': {stderr_crb}"
            print(json.dumps(result, indent=2))
            return 1

        result["resources_deleted"] = [
            f"serviceaccount/{args.username}",
            f"clusterrolebinding/{crb_name}",
        ]

        # Remove the namespace as well if create_access_key.py created it and
        # nothing else (such as a tenant installed there since) lives in it.
        _, created_ns, _ = _run(
            [
                "kubectl",
                "get",
                "namespaces",
                "-l",
                CREATED_BY_LABEL,
                "--field-selector",
                f"metadata.name={ns}",
                "-o",
                "name",
            ],
            env,
        )
        if created_ns:
            rc_list, contents, _ = _run(["kubectl", "get", "serviceaccounts,pods", "-n", ns, "-o", "name"], env)
            if rc_list == 0 and not [obj for obj in contents.splitlines() if obj != "serviceaccount/default"]:
                rc_ns, _, stderr_ns = _run(
                    ["kubectl", "delete", "namespace", ns, "--ignore-not-found=true", "--timeout=120s"],
                    env,
                )
                if rc_ns != 0:
                    result["error"] = f"Failed to delete namespace '{ns}': {stderr_ns}"
                    print(json.dumps(result, indent=2))
                    return 1
                result["resources_deleted"].append(f"namespace/{ns}")

        result["message"] = (
            f"ServiceAccount '{args.username}' deleted from namespace '{ns}'. "
            "Kubernetes garbage-collected all owned secrets."
        )
        result["success"] = True

    except Exception as exc:  # pylint: disable=broad-except
        result["error"] = str(exc)

    print(json.dumps(result, indent=2))
    return 0 if result["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
