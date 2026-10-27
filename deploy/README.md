# Deploy

Packaging and deployment assets for the applications in [`apps/`](../apps).

- [`helm/`](helm) holds the shared Helm chart for the four services, their values files and the image values that CI will update. Argo CD deploys it to clusters labelled `platform.example/apps=true` (off by default); see the [service deployment runbook](../docs/runbooks/service-deployment.md) and [ADR-0016](../docs/adr/0016-service-deployment-model.md).
- Check it with `make deploy-check`.
