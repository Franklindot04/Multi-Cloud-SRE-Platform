# ADR-0005: Observability stack choice

- Status: Accepted
- Date: 2026-10-25

## Context

The platform needs metrics, logs and traces from two clouds, plus SLO evaluation and alerting. The stack should be portable across clusters, based on open standards, and avoid coupling the platform to one provider's monitoring product.

## Decision

- Instrumentation: OpenTelemetry for traces, metrics and log correlation in services.
- Metrics: Prometheus (via the kube-prometheus-stack) in each cluster, with long-term and cross-cluster querying through a Thanos or Mimir style backend to be selected when Phase 4 begins.
- Logs: Loki with a lightweight collector such as Promtail or the OpenTelemetry Collector.
- Traces: Tempo.
- Visualisation: Grafana, with dashboards provisioned from Git.
- Alerting: Alertmanager routing to an on-call tool; SLO recording rules and multi-window burn-rate alerts generated from SLO definitions (for example with Sloth or Pyrra).
- Native cloud monitoring (CloudWatch, Cloud Monitoring) is used only for provider-level signals that are not otherwise available, and is exported or scraped into the common stack where practical.

## Consequences

- One consistent query and alerting model across both clouds.
- Open standards limit lock-in and keep skills transferable.
- The team runs and scales the stack itself, including its storage and its own monitoring.
- The final choice of long-term metrics backend is deferred and will be recorded in a follow-up ADR.

## Alternatives considered

- Managed vendor platforms (for example Datadog): faster to start, but cost and lock-in conflict with the learning goals.
- Cloud-native monitoring only: low effort, but two different models and weak cross-cloud views.
- Elastic stack for logs: capable, but heavier to operate than Loki for this scale.
