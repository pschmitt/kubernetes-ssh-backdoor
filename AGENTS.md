# Agent instructions

This repository deploys Kubernetes resources and scripts for an SSH tunnel and credential transfer workflow. Treat it as privileged infrastructure code: never include real credentials, endpoints, cluster identifiers, or topology in shared documentation.

## Working and validation

- Read the target script and manifests together before changing install, tunnel, or credential handling.
- Validate shell syntax and manifest structure without applying changes to a live cluster. Use an isolated test context for integration checks.
- Before changing GitHub Actions, check whether [pschmitt/ci-workflows](https://github.com/pschmitt/ci-workflows) provides a reusable workflow or action. Preserve current behavior and check coverage, and use `@main` for shared workflow or action references.
