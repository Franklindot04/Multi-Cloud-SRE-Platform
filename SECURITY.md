# Security policy

This is a solo-maintained portfolio project. It is looked after in spare time, so this policy says only what can actually be delivered.

## Supported versions

Only these receive security fixes:

- the latest commit on `main`
- the latest tagged release

Older commits, older tags and forks are not supported.

## Reporting a vulnerability

Please report security problems privately, and do not open a public issue or pull request for them.

1. Use GitHub's private vulnerability reporting for this repository: open the **Security** tab and choose **Report a vulnerability**.
2. If that does not work for you, email <ajerofranklin_dev@proton.me>.

Please include:

- what you found and where (file, workflow, chart, image or configuration)
- the commit, tag or image digest you looked at
- steps to reproduce it, or a short proof of concept
- the impact as you understand it
- any fix you would suggest, if you have one

Do not include real credentials or other people's data in a report.

## What to expect

Reports are looked at on a best-effort basis. I aim to acknowledge a report within seven days. There is no guaranteed time to a fix, no service level agreement and no bug bounty. If a report is valid, the fix is made in the open on `main` once it is ready, and the reporter is credited if they want to be.

## Scope

This repository is a reference platform: sample services and Terraform, Helm and Argo CD configuration. It holds no real customer data and runs no production service.

In scope:

- the code in this repository (the sample services, the scripts, the Terraform, Helm and Argo CD configuration)
- the GitHub Actions workflows
- the container images published to GitHub Container Registry by this repository's workflow

Not in scope:

- third-party software the platform deploys, such as Argo CD, the CloudNativePG and RabbitMQ operators, cert-manager and the observability components. Please report those to their own projects.
- weaknesses in a cluster or cloud account that someone else built from this repository
- findings that need access the project does not give out, or that only affect the reporter's own fork

## Supply chain

The service images (gateway, orders, payments, notifier) that the images workflow publishes from `main` are scanned for known, fixable vulnerabilities, signed keylessly with the workflow's GitHub identity, and carry an SBOM and build provenance tied to their digest. `scripts/verify-image.sh` checks the signature, the SBOM attestation and the provenance. How to run it, and what a pass means, is in [Verify an image](docs/runbooks/service-deployment.md#verify-an-image).

This has run for real: the images workflow's publish job on `main` (commit `106d729`) scanned, signed and attested all four images and its own verification passed. `scripts/verify-image.sh` also passed on all four digests from a developer machine, and it passes against the digests now in `deploy/helm/values/images.yaml`.

This has limits, which [ADR-0019](docs/adr/0019-image-supply-chain.md) lists in full. In short:

- the signed images have not been deployed to a cluster yet, and nothing in a cluster checks signatures
- images that were published earlier are not rescanned, and fixable-only scanning means unfixed vulnerabilities are not reported
- a signature says the digest came from this repository's images workflow on `main`, not that the code was reviewed or is safe
- the provenance is the build platform's own statement, and no SLSA level is claimed
- base images are pinned by version tag, not by digest
