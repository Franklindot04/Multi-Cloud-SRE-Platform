# network-policies

Default-deny network policies for the `kyverno` namespace, with the allow rules the Kyverno controllers need. They are enforced by the VPC CNI on EKS; the chart is deployed to EKS clusters only. They have not been applied to a cluster yet: everything here is checked offline by `scripts/network-policies-check.sh`, which evaluates the flows of [the matrix](../../../scripts/tests/fixtures/network-policies/flows.yaml) against the rendered policies. Design: [ADR-0024](../../../docs/adr/0024-network-policies.md); operation: [network policy runbook](../../../docs/runbooks/network-policies.md).

**Order.** Every allow rule has sync wave -2 and the default deny wave -1, so a deny never lands without them. The Application is wave 19, after Kyverno (wave 18).

**The two ranges.** The VPC CNI policy agent matches an egress rule against the address the pod connects to, so the API server and the cluster DNS, which are Services, are reached through the **Service range** (`serviceCidr`, from the annotation `platform.example/service-cidr`). The API server calls the admission webhook from its own network interfaces, which are in the VPC subnets, straight to the pod, so the webhook port accepts the **VPC range** (`vpcCidr`, from `platform.example/vpc-cidr`). Neither is committed, and the chart refuses to render without them.

| Policy | From | To | Port |
| --- | --- | --- | --- |
| `default-deny` | | every pod in `kyverno`, ingress and egress | none |
| `allow-dns` | every pod | `kube-dns` in `kube-system`, and the Service range | UDP and TCP 53 |
| `allow-kube-api-*` | the four controllers and the migration Job | the Service range (the API) | TCP 443 |
| `admission-allow-webhook-from-api-server`, `cleanup-allow-webhook-from-api-server` | the VPC range | the admission and cleanup controllers | TCP 9443 |
| `<controller>-allow-prometheus-scrape` | Prometheus in `observability` | each controller | TCP 8000 |
| `admission-allow-internet-https` | the admission controller | every address except the VPC and Service ranges | TCP 443 |

**The internet rule.** The admission controller will check image signatures and attestations when policies ask for it: it reaches a registry and, for keyless verification, the Sigstore services (Fulcio, Rekor, the TUF root). Those are public addresses that no pod selector can name, so this one policy opens TCP 443 to `0.0.0.0/0` for the admission controller only, leaving out the VPC and Service ranges (which have their own rules). The policy carries an annotation that says why, and `scripts/chart-contract-check.py network-policies` accepts a `/0` range only with that annotation and only on TCP 443. No other pod has egress to the internet.

**Switching off.** `enabled: false` renders nothing and Argo CD prunes the policies.
