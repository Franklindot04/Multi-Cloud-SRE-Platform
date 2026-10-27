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

Phase 0 (foundation) is in progress, and Phases 1 to 3 have started. The repository structure, conventions, linting and CI are in place; the Terraform bootstrap stacks, the network and cluster modules for both clouds, the optional DNS modules, the cluster baseline add-ons and the Argo CD hub are defined, tested and validated. The sample order-processing application runs with in-memory storage, and the data layer it will move to (PostgreSQL, a Valkey cache and RabbitMQ, with their operators and in-cluster credential generation) is now defined in `platform/data` with a local Compose stack; it is off by default on clusters and the services are not wired to it yet. No network, cluster, add-on or data component has been bootstrapped or deployed by this repository's automation.

## Getting started

```bash
make help
make lint
```

Contribution guidelines are in [CONTRIBUTING.md](CONTRIBUTING.md). Install the pre-commit hooks with `pre-commit install`.

## License

[MIT](LICENSE)
