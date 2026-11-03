# external-secrets-store

The `ClusterSecretStore` **aws-parameter-store** (`external-secrets.io/v1`): AWS Systems Manager Parameter Store, in the region of the cluster, signing in with the web identity token of the service account `external-secrets` in the namespace `external-secrets` (`auth.jwt.serviceAccountRef`). The operator exchanges the token for the IAM role of that service account. **The chart holds no credential of any kind**: no secret reference, no key pair, no token. The contract check `eso-store` fails if one appears.

```yaml
spec:
  provider:
    aws:
      service: ParameterStore
      region: eu-north-1          # from the cluster annotation platform.example/region
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

The API version and the fields were read from the CRD of the pinned chart (2.14.0): `external-secrets.io/v1` is the served and stored version, `v1beta1` is deprecated and not served, and `region` and `service` are the required fields of the AWS provider.

| Value | From | Meaning |
| --- | --- | --- |
| `region` | the cluster annotation `platform.example/region` | AWS region of the parameters; the chart refuses to render without it |
| `parameterPrefix` | the cluster annotation `platform.example/secrets-prefix` (Terraform output `secrets_parameter_prefix`, for example `/multi-cloud-sre/dev`) | recorded on the store as the annotation `platform.example/parameter-prefix`; the chart refuses to render without it |

The store does not use the path to read anything: the keys of the ExternalSecrets are the full parameter names listed in [`scripts/secrets/manifest.yaml`](../../../scripts/secrets/manifest.yaml), and the IAM role can only read `/<prefix>/<environment>/*`. Argo CD deploys it (wave 4, after the operator whose CRDs define the kind; the object carries `SkipDryRunOnMissingResource`) to EKS clusters labelled `platform.example/external-secrets=true`. The values are written to Parameter Store by `scripts/seed-secrets.sh`. Nothing has run on a cluster or against AWS.
