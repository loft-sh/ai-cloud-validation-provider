# Security

## Reporting a vulnerability

Report vulnerabilities in these providers or in vCluster privately to
[security@vcluster.com](mailto:security@vcluster.com), as described in
[vCluster's security policy](https://github.com/loft-sh/vcluster/blob/main/.github/SECURITY.md).
Do not open a public issue for them.

Vulnerabilities in the validation suite itself belong to NVIDIA: see
[its security policy](https://github.com/NVIDIA/ai-cloud-validation/blob/main/SECURITY.md).

## What the providers do when they run

The scripts run on the machine that starts the suites, with that machine's
credentials:

- They use the kubeconfig in `KUBECONFIG` to create and delete vCluster
  instances, namespaces, ServiceAccounts and ClusterRoleBindings on the control
  plane cluster. The kubeconfig needs rights to do all of that, so run them
  against a cluster meant for validation.
- They log in to vCluster Platform with `VCLUSTER_PLATFORM_ACCESS_KEY`, using a
  vcluster CLI config of their own (never `~/.vcluster`). Connecting a tenant
  to the Platform creates an access key for it there, stored as a Secret in the
  tenant's namespace on the control plane cluster; deleting the tenant removes
  both.
- `setup.sh` connects to the worker nodes in `VCLUSTER_NODES` over SSH and runs
  vCluster's node join script on them as root, which installs containerd,
  kubelet and kube-proxy. The join command carries a bootstrap token that
  expires after an hour; it goes to the nodes over stdin and is never printed.
  `teardown.sh` runs the same script's reset mode, then deletes the tenant's
  local-path volumes and pod logs from the nodes. containerd's image cache and
  the NVIDIA driver stay, so reimage the nodes before another tenant gets them.
  Point `VCLUSTER_NODES` only at machines meant for this cluster.
- `setup.sh` writes the tenant's kubeconfig, which holds its admin
  credentials, to `VCLUSTER_KUBECONFIG_PATH` (default
  `/tmp/vcluster-isv-validation.kubeconfig`) with mode 600, and next to it the
  CLI config with the Platform login, the tenant's values and the network ACL
  probe script; `teardown.sh` deletes them. The suite runs that script, so on a
  machine other people use, set `VCLUSTER_KUBECONFIG_PATH` to a directory only
  you can write to.
- The tenant's API server is exposed through a LoadBalancer that admits only
  `VCLUSTER_API_ALLOWED_CIDRS` (default: the public IPv4 addresses of this
  machine and of the worker nodes).
- With `VCLUSTER_OIDC_ISSUER_URL` set, `setup.sh` publishes the tenant's service
  account issuer document and public signing keys, which are public by design,
  with `VCLUSTER_OIDC_PUBLISH_CMD`.
- `NGC_API_KEY` is used only for nvcr.io image pull secrets in the tenant's
  cluster. The scripts do not print it or pass it on a command line.

vCluster Labs is SOC 2 certified: <https://trust.vcluster.com/>.
