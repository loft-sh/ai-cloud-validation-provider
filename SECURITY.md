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
  plane cluster, and `setup.sh` lifts the `nvidia.com/gpu:NoSchedule` taint from
  GPU nodes for the run (`teardown.sh` restores it). The kubeconfig needs rights
  to do all of that, so run them against a cluster meant for validation.
- `setup.sh` writes the tenant's kubeconfig, which holds its admin
  credentials, to `VCLUSTER_KUBECONFIG_PATH` (default
  `/tmp/vcluster-isv-validation.kubeconfig`) with mode 600, and the network ACL
  probe script next to it; `teardown.sh` deletes both. The suite runs that
  script, so on a machine other people use, set `VCLUSTER_KUBECONFIG_PATH` to a
  directory only you can write to.
- On cloud clusters the tenant's API server is exposed through a LoadBalancer
  that admits only `VCLUSTER_API_ALLOWED_CIDRS` (default: this machine's public
  IPv4 address).
- `NGC_API_KEY` is used only for nvcr.io image pull secrets in the tenant's
  cluster. The scripts do not print it.

vCluster Labs is SOC 2 certified: <https://trust.vcluster.com/>.
