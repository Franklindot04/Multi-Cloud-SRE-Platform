# Multi-Cloud SRE Platform

A reference platform for running a small microservice workload on Kubernetes across AWS and GCP, with GitOps delivery, full-stack observability and reliability managed through service level objectives.

The goal is to demonstrate, end to end, how a platform team provisions, operates and improves a multi-cloud environment: infrastructure as code, declarative delivery, measurable reliability and rehearsed failure response.

## Goals

- Provision repeatable infrastructure on AWS (EKS) and GCP (GKE) with Terraform.
- Deliver all cluster and application configuration through GitOps with Argo CD.
- Instrument services and clusters for metrics, logs and traces.
- Define SLOs per service and alert on error budget burn rather than raw symptoms.
- Practise incident response through planned failure scenarios, runbooks and blameless postmortems.
- Keep decisions documented as ADRs so the reasoning stays reviewable.

## Architecture

Two Kubernetes clusters, one per cloud, run the same set of sample services (`gateway`, `orders`, `payments`, `notifier`). Terraform provisions networking, clusters and identity on each side. A central Argo CD instance reconciles platform add-ons and applications from this repository onto both clusters. An observability stack collects telemetry from each cluster and evaluates SLOs and burn-rate alerts. Traffic is distributed across clouds through DNS-based routing with health checks.

See [docs/architecture/overview.md](docs/architecture/overview.md) for the full description and diagram.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`infra/terraform`](infra/terraform) | Terraform bootstrap, modules and per-cloud environments |
| [`platform`](platform) | Argo CD, cluster add-ons, observability and security configuration |
| [`apps`](apps) | Sample microservices |
| [`deploy/helm`](deploy/helm) | Helm charts and values for the services |
| [`docs`](docs) | Architecture, ADRs, runbooks, postmortems and SLOs |
| [`scripts`](scripts) | Helper scripts |
| [`.github`](.github) | CI workflows and issue/PR templates |

## Roadmap

| Phase | Scope |
| --- | --- |
| 0. Foundation | Repository structure, conventions, ADRs, linting and CI, Terraform bootstrap and state backends |
| 1. Cloud infrastructure | AWS and GCP networking, EKS and GKE clusters, DNS and global traffic management |
| 2. Platform layer | Cluster baseline add-ons (ingress, external-dns, cert-manager, metrics-server), Argo CD bootstrap with app-of-apps |
| 3. Application | Sample microservices, data layer, Helm charts, CI pipeline, supply chain (SBOM, scanning, signing) |
| 4. Observability | OpenTelemetry, metrics, logs, traces, SLIs/SLOs, burn-rate alerting, notifications |
| 5. Security | Secrets management and KMS, admission policies, RBAC, network policies, mTLS |
| 6. Reliability | Resilience patterns, autoscaling, progressive delivery and automated rollback, chaos testing, automated remediation, DR and cross-cloud failover |
| 7. Operations and close-out | Runbooks, postmortems, incident simulation, cost controls, production-readiness review |

## Status

Phase 0 (foundation) is in progress, and Phases 1 to 3 have started. The repository structure, conventions, linting and CI are in place; the Terraform bootstrap stacks, the network and cluster modules for both clouds, the optional DNS modules, the cluster baseline add-ons and the Argo CD hub are defined, tested and validated. The sample order-processing application runs with in-memory storage by default and can be switched, by environment variables, to the data layer defined in `platform/data` (PostgreSQL, a Valkey cache and RabbitMQ, with their operators and in-cluster credential generation): orders and payments store their data in PostgreSQL with forward-only migrations, orders publishes events through a transactional outbox to RabbitMQ, and the notifier consumes them. This is exercised locally with `make integration-test`; the data layer is off by default on clusters, and a shared Helm chart and Argo CD ApplicationSets that deploy the four services to Kubernetes (migrations as PreSync Jobs, RabbitMQ credentials copied into the `shop` namespace) are now defined and validated, and were tested on a throwaway local cluster; they are off by default on clusters. CI now lints, tests and integration-tests the services and builds their images for `linux/amd64`, and publishes them to GitHub Container Registry on merges to `main` (tagged with the commit SHA; the chart's image tag stays a placeholder until a pull request updates it with `scripts/update-image-values.sh`). The first run of the data layer and the services on a real EKS cluster found that the credential charts never synced (they held only hooks), that PostgreSQL was applied before its role Secrets existed, and that teardown needed a different order; these are fixed in the charts (ordinary resources next to the hook Jobs, a PreSync gate for PostgreSQL), checked by new contract checks, and the teardown is automated by `scripts/teardown-prep.sh` (tested against fakes, not yet against a real cluster; [ADR-0018](docs/adr/0018-secret-generation-and-ordering.md)). The fixes have been tested on throwaway local clusters only, not yet on the real one, and the cause of a roughly 17-minute delay in PostgreSQL role reconciliation seen there was not reproduced. The image workflow now also scans every changed image with Trivy on pull requests, and on a merge to `main` signs each published digest keylessly, attaches an SBOM and build provenance and verifies them (`scripts/verify-image.sh`, [ADR-0019](docs/adr/0019-image-supply-chain.md)). The first publish did this for all four images and the digests in `deploy/helm/values/images.yaml` now pass `scripts/verify-image.sh all`; those signed images have not been deployed to a cluster yet, and nothing in a cluster checks signatures. No network, cluster, add-on or data component has been bootstrapped or deployed by this repository's automation.

## Getting started

```bash
make help
make lint
```

Contribution guidelines are in [CONTRIBUTING.md](CONTRIBUTING.md). Install the pre-commit hooks with `pre-commit install`.

## Policies

- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md), including how to report a vulnerability privately

## License

[MIT](LICENSE)
