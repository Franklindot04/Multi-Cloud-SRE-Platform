# Vendored IAM policies

| File | Source | Version | SHA-256 |
| --- | --- | --- | --- |
| `aws-load-balancer-controller.json` | [kubernetes-sigs/aws-load-balancer-controller `docs/install/iam_policy.json`](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.6.2/docs/install/iam_policy.json) | `v3.6.2` (matches the pinned chart's app version) | `16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a` |

The file is the controller project's official policy, unmodified, fetched on 2026-10-26. JSON cannot hold comments, so the source is recorded here.

To update it, change the version in the URL to the new controller release, download the file, update the table above, and review the diff for added permissions before applying. Keep it in step with the chart version pinned in `platform/addons/aws-load-balancer-controller`.

The external-dns and cert-manager policies are small and defined inline in `addons-iam.tf`, scoped to a single hosted zone.
