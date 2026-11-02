# external-secrets-network-policies

Default-deny network policies for the `external-secrets` namespace and the allow rules of the External Secrets Operator's three pods (the controller, the webhook and the certificate controller). Argo CD deploys it to EKS clusters labelled `platform.example/external-secrets=true` (wave 4, `platform/argocd/apps/89-eso-network-policies.yaml`); it takes the Service range and the VPC range from the cluster annotations `platform.example/service-cidr` and `platform.example/vpc-cidr` and refuses to render without them. The allow rules have sync wave -2 and the default deny -1.

| Pod | Ingress | Egress |
| --- | --- | --- |
| controller | Prometheus on 8080 | DNS; the API server (Service range, 443); the internet on 443 (AWS STS and Systems Manager) |
| webhook | the API server on 10250 (the VPC range, straight to the pod); Prometheus on 8080 | DNS; the API server (Service range, 443) |
| cert-controller | Prometheus on 8080 | DNS; the API server (Service range, 443) |

Only the controller can reach the internet, on TCP 443, to any address except the VPC and Service ranges. The policy carries the annotation `platform.example/internet-egress` with the reason, which the contract check requires for a `/0` range. Whether the webhook and the certificate controller really need the API server is taken from the chart; it has not been seen on a cluster. The flows are in the matrix [`flows.yaml`](../../../scripts/tests/fixtures/network-policies/flows.yaml) and are evaluated by `make network-policies-check`; nothing has been applied to a cluster.
