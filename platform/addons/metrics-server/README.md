# metrics-server

Serves the resource metrics API used by `kubectl top` and the Horizontal Pod Autoscaler. Chart: `metrics-server` 3.14.0 from `https://kubernetes-sigs.github.io/metrics-server/`.

- **Namespace:** `kube-system`
- **Cloud:** EKS only. GKE ships and manages its own metrics-server, so none is installed there.
- **Replicas and disruption:** 2 replicas, `minAvailable: 1`, preferred anti-affinity across nodes, `system-cluster-critical`.
- **Permissions:** none outside the cluster, so there is no IRSA role.
- **EKS override:** nodes are addressed by `InternalIP`.
