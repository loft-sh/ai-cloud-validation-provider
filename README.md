# vCluster providers for the NVIDIA AI Cloud Validation Suite

> These providers are maintained by vCluster Labs, not by NVIDIA. NVIDIA does
> not endorse or support them. Report issues at
> <https://github.com/loft-sh/ai-cloud-validation-provider/issues>.

Providers that connect [vCluster](https://www.vcluster.com) to the
[NVIDIA AI Cloud Validation Suite](https://github.com/NVIDIA/ai-cloud-validation)
through its
[provider registry](https://github.com/NVIDIA/ai-cloud-validation/blob/main/docs/guides/provider-registry.md).
Each provider lives in its own directory with its own `config/` and `scripts/`
and has its own registry entry.

| Provider | Tenancy model | Suites | Validated against |
|---|---|---|---|
| [`vcluster`](vcluster/) | Private Nodes | `k8s`, `control-plane` | 1.0.0 ([results](vcluster/README.md#results)) |

## Reproducing the results

Prerequisites, credentials and the exact commands are in
[vcluster/README.md](vcluster/README.md#reproducing).

## Continuous checks

[`.github/workflows/validate.yml`](.github/workflows/validate.yml) loads every
provider config against the latest ai-cloud-validation release with `--dry-run`
on every change and every week, which is the check NVIDIA's registry CI runs.
It needs no cluster: it catches a release that changes the suite contract, not
a platform regression.

## Community and security

- [Contributing](CONTRIBUTING.md): checks to run before a pull request, and how a
  validated commit reaches the registry.
- [Security](SECURITY.md): private vulnerability reporting, and what the
  scripts do on the machine and clusters they run against.

## License

Apache-2.0, see [LICENSE](LICENSE).
