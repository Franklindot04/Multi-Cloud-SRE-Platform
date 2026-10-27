# namespaces

Creates the `data` namespace (PostgreSQL, Valkey, RabbitMQ) and the `shop` namespace (the application services) with Pod Security Admission labels.

| Namespace | Enforced level | Why |
| --- | --- | --- |
| `data` | `baseline` (warn and audit `restricted`) | The RabbitMQ pods come from the RabbitMQ Cluster Operator. Its pod spec is not documented as `restricted`-compliant and the broker writes to its root filesystem. PostgreSQL and Valkey are configured to meet `restricted`. |
| `shop` | `restricted` | The services are written for it. |

`warn` and `audit` are always `restricted`, so any pod that would not pass the strictest level is reported. Tighten `data` to `restricted` once those warnings are clean. The namespaces are annotated so that Argo CD never prunes or deletes them.
