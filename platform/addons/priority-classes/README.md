# priority-classes

Defines `platform-addons-critical` (value 1,000,000), used by add-ons that run in their own namespaces (cert-manager, external-dns). The built-in `system-cluster-critical` class is reserved for `kube-system`, so add-ons deployed there (the load balancer controller and metrics-server) use that class instead.

Deploy this first: it uses sync wave `-10`. It applies to both clouds and has no cloud-specific values.
