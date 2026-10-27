# priority-classes

Defines `platform-addons-critical` (value 1,000,000), used by add-ons that run in their own namespaces (cert-manager, external-dns), and `platform-apps` (value 100,000), used by the sample application services ([ADR-0016](../../../docs/adr/0016-service-deployment-model.md)); the add-ons rank above the services they depend on. The built-in `system-cluster-critical` class is reserved for `kube-system`, so add-ons deployed there (the load balancer controller and metrics-server) use that class instead.

Deploy this first: it uses sync wave `-10`. It applies to both clouds and has no cloud-specific values.
