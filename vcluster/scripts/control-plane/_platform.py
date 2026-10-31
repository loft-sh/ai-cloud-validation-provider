#!/usr/bin/env python3
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

"""vcluster CLI logged in to vCluster Platform, for the tenant scripts.

Private Nodes is a vCluster Free tier feature licensed through vCluster
Platform: vcluster create connects each tenant to the Platform the CLI is
logged in to. The login goes to a CLI config of its own, never ~/.vcluster.
"""

import contextlib
import os
import subprocess
import tempfile
from collections.abc import Iterator


@contextlib.contextmanager
def vcluster_cli(env: dict[str, str]) -> Iterator[list[str]]:
    """Yield the vcluster command prefix, logged in to VCLUSTER_PLATFORM_HOST."""
    host = env.get("VCLUSTER_PLATFORM_HOST", "")
    key = env.get("VCLUSTER_PLATFORM_ACCESS_KEY", "")
    key_file = env.get("VCLUSTER_PLATFORM_ACCESS_KEY_FILE", "")
    if not key and key_file:
        with open(key_file, encoding="utf-8") as f:
            key = f.read().strip()
    if not host or not key:
        raise RuntimeError(
            "set VCLUSTER_PLATFORM_HOST and VCLUSTER_PLATFORM_ACCESS_KEY "
            "(Private Nodes is licensed through vCluster Platform)"
        )
    with tempfile.TemporaryDirectory() as tmp:
        config = os.path.join(tmp, "config.json")
        cmd = [
            "vcluster",
            "--config",
            config,
            "platform",
            "login",
            host,
            "--access-key",
            key,
            "--docker-login=false",
        ]
        if env.get("VCLUSTER_PLATFORM_INSECURE") == "true":
            cmd.append("--insecure")
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if proc.returncode != 0:
            raise RuntimeError(f"vcluster platform login failed: {proc.stderr.strip()}")
        yield ["vcluster", "--config", config]
