# Runbooks

Step-by-step procedures for responding to alerts and performing routine operations. Every paging alert should link to a runbook.

The [alert runbook](alerts.md) has one section for each alert of the platform; the alerts link to its anchors. The [network policy runbook](network-policies.md) covers applying the network policies, checking each path, seeing what is dropped and rolling back. The [Kyverno runbook](kyverno.md) covers applying the policy engine and the admission policies, the checks after an apply, reading policy reports, moving a policy from Audit to Enforce, a blocked deploy, and teardown. The [resilience runbook](resilience.md) covers applying the budgets, the spread, the autoscalers, the priority classes and the second PostgreSQL instance, the checks after an apply, a load test, a drain test, a switchover test, a Pending pod or a blocked drain, and capacity. The [secrets runbook](secrets.md) covers the first-time setup of the secrets in Parameter Store, the checks after an apply, reading an ExternalSecret error, rotation, switching between the generated and the external mode, the free parameters between sessions, and teardown.

Each runbook covers: symptoms, impact, diagnosis, mitigation, escalation and follow-up. Use a file name of the form `<service>-<condition>.md`.
