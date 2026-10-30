# Contributing

Issues and pull requests are welcome. vCluster Labs maintains these providers;
NVIDIA does not.

## Before you open a pull request

From a checkout of the ai-cloud-validation release named in the provider's
registry entry (`tested_with`), with this repository cloned next to it:

```bash
# The configs still load against the release (what NVIDIA's registry CI checks)
uv run isvctl test run --no-upload --dry-run -f ../ai-cloud-validation-provider/vcluster/config/k8s.yaml
uv run isvctl test run --no-upload --dry-run -f ../ai-cloud-validation-provider/vcluster/config/control-plane.yaml

# Lint, with the release's ruff configuration
uvx ruff check --config pyproject.toml ../ai-cloud-validation-provider/vcluster/scripts
uvx ruff format --check --config pyproject.toml ../ai-cloud-validation-provider/vcluster/scripts
shellcheck -S warning ../ai-cloud-validation-provider/vcluster/scripts/k8s/*.sh
```

A change that affects what runs against a cluster also needs a live run of the
affected suite. Say in the pull request what you ran and what you could not.

## Releasing a validated commit

The registry entry in NVIDIA/ai-cloud-validation pins one commit of this
repository. After a change merges and passes the live suites against a release:

1. Update the provider README's results for that commit.
2. Open a pull request in NVIDIA/ai-cloud-validation that changes `commit`
   (and `tested_with`, for a new release) in
   `isvctl/configs/providers-registry/<name>.yaml`, following its
   [provider registry guide](https://github.com/NVIDIA/ai-cloud-validation/blob/main/docs/guides/provider-registry.md).
   Commits there must be signed off (DCO).

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
