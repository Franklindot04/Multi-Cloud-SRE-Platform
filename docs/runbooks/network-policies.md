# Network policies: apply, check, debug and roll back

For someone applying the policies for the first time, and for someone debugging a blocked connection. What the policies are and why is in [ADR-0024](../adr/0024-network-policies.md). The policies of the `shop` namespace are in the [service chart](../../deploy/helm/README.md#network-policies), those of `data` in [`platform/data/network-policies`](../../platform/data/network-policies) and those of `observability` in [`platform/observability/network-policies`](../../platform/observability/network-policies).

**Nothing in this runbook has been run on a cluster.** The commands are written from the manifests and the tools' documentation. The offline checks prove that the policies mean what we intend under the standard semantics; they cannot prove how the VPC CNI policy agent behaves, which is what the checks below are for.

## Apply

The order matters, and each step has a way to see that it worked.

1. **Terraform: the add-on.** `terraform apply` in `infra/terraform/environments/aws` sets `enableNetworkPolicy` on the `vpc-cni` add-on (`enable_network_policy`, default true). See [network policy enforcement](aws-eks.md#network-policy-enforcement) for the update of an existing cluster. Wait until the `aws-node` DaemonSet is fully rolled out and each pod has the `aws-network-policy-agent` container.
2. **The bootstrap script, again.** It writes the annotation `platform.example/vpc-cidr` on the cluster Secret, from the Terraform output `vpc_cidr_block`. Repeat the flags you already use (the script writes every label on each run).

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Until the annotation exists the two policy Applications (`data-network-policies-*` and `observability-network-policies-*`) fail to sync with the message that `vpcCidr` must be set. That is intended: a deny must not land without the API rule.
3. **Argo CD syncs the policies.** The service policies come with the services (wave 20 to 22), the data policies at wave 9 and the observability policies at wave 17. In each Application the allow rules go first (sync wave -2) and the default deny after them (wave -1).
4. **Check, in this order** (below). Stop at the first class that fails.

## Check after an apply

The probes use an ephemeral container, because the service images have no shell and an ephemeral container shares the pod's network namespace, so it is subject to the pod's own policies: it tests the real path. Nothing is installed on the pod, and the container disappears with the pod.

The debug image is busybox 1.37, pinned by digest. The digest below was read from the registry on 2026-11-01 (`docker buildx imagetools inspect busybox:1.37`; it is the digest of the multi-architecture index). Read it again before you rely on it, and replace it when you move to another version:

```bash
export DEBUG_IMAGE='docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
```

The `shop` and `observability` namespaces enforce the restricted Pod Security level, which applies to ephemeral containers too, and busybox runs as root by default. This file gives the container a non-root user and drops its capabilities (`kubectl debug --custom` needs kubectl 1.27 or later):

```bash
cat > /tmp/debug-container.json << 'EOF'
{
  "securityContext": {
    "runAsNonRoot": true,
    "runAsUser": 65534,
    "runAsGroup": 65534,
    "allowPrivilegeEscalation": false,
    "capabilities": {"drop": ["ALL"]},
    "seccompProfile": {"type": "RuntimeDefault"}
  }
}
EOF
```

A small function runs one command in a pod of a workload. It takes the namespace, a label selector and the command:

```bash
probe() {
  local ns="$1" selector="$2" pod
  shift 2
  pod="$(kubectl --context <EKS_CONTEXT> -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
  kubectl --context <EKS_CONTEXT> -n "$ns" debug -it "$pod" --image="$DEBUG_IMAGE" --custom=/tmp/debug-container.json -q -- "$@"
}
```

Each call adds an ephemeral container to the pod (they cannot be removed). Reuse one with `kubectl attach` if you probe the same pod many times. Remove the file when you are done.

### 1. DNS first

DNS is the canary. Every other path starts with a name lookup, and it is also the check of the open question in the ADR: whether the policy agent compares the address of the pod behind a Service, which is what the policies are written for, or the Service address.

```bash
probe shop app.kubernetes.io/name=orders nslookup kubernetes.default.svc.cluster.local
probe data cnpg.io/cluster=platform-pg nslookup kubernetes.default.svc.cluster.local
probe observability app.kubernetes.io/name=grafana nslookup kubernetes.default.svc.cluster.local
```

All three must print an address. If they time out:

- Look for the same name through a CoreDNS pod directly. Get a pod address with `kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide`, then `probe shop app.kubernetes.io/name=orders nslookup kubernetes.default.svc.cluster.local <COREDNS_POD_IP>`.
- If the lookup through the pod address works and the one through the cluster DNS Service address (the `nameserver` in `/etc/resolv.conf`) does not, the agent is comparing the Service address. The policies would then need a rule for the Service address range. **Stop and roll back** (below); that is a design change.
- If both fail, the policy is blocking DNS on the pod: look at the pod's policies (`kubectl -n <ns> get networkpolicy`), and at the drops (below).

### 2. The request path

```bash
probe shop app.kubernetes.io/name=gateway wget -q -O- -T 3 http://orders:8081/readyz
probe shop app.kubernetes.io/name=gateway wget -q -O- -T 3 http://payments:8082/readyz
probe shop app.kubernetes.io/name=orders wget -q -O- -T 3 http://payments:8082/readyz
```

Each must print a small JSON document. The gateway has no shell either, so it is the ephemeral container that opens the connection, with the gateway's policies. Then paths that must be closed (each prints `closed` after three seconds):

```bash
probe shop app.kubernetes.io/name=payments sh -c 'wget -q -O- -T 3 http://orders:8081/readyz > /dev/null && echo "open (should be closed)" || echo closed'
probe shop app.kubernetes.io/name=notifier sh -c 'wget -q -O- -T 3 http://payments:8082/readyz > /dev/null && echo "open (should be closed)" || echo closed'
```

### 3. The services and the data layer

```bash
probe shop app.kubernetes.io/name=orders sh -c 'nc -w 3 platform-pg-rw.data.svc 5432 </dev/null && echo postgres ok || echo postgres BLOCKED'
probe shop app.kubernetes.io/name=payments sh -c 'nc -w 3 platform-pg-rw.data.svc 5432 </dev/null && echo postgres ok || echo postgres BLOCKED'
probe shop app.kubernetes.io/name=orders sh -c 'nc -w 3 platform-valkey.data.svc 6379 </dev/null && echo valkey ok || echo valkey BLOCKED'
probe shop app.kubernetes.io/name=orders sh -c 'nc -w 3 platform-mq.data.svc 5672 </dev/null && echo rabbitmq ok || echo rabbitmq BLOCKED'
probe shop app.kubernetes.io/name=notifier sh -c 'nc -w 3 platform-mq.data.svc 5672 </dev/null && echo rabbitmq ok || echo rabbitmq BLOCKED'
```

And one that must fail, to see that the deny holds: `probe shop app.kubernetes.io/name=gateway sh -c 'nc -w 3 platform-pg-rw.data.svc 5432 </dev/null && echo postgres OPEN || echo closed'` must print `closed`. Then confirm the real services are healthy, since that exercises the same paths with the real clients: `kubectl -n shop get pods` (all ready; the data profile's `/readyz` needs the database and the broker), and the migration Jobs completed.

The operators: `kubectl -n data get cluster platform-pg` shows `Cluster in healthy state`, and `kubectl -n data get rabbitmqcluster platform-mq` shows `AllReplicasReady` true. If an operator cannot reach its instances, see [the operators](#an-operator-cannot-reach-its-instances).

### 4. Prometheus targets

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In another terminal:

```bash
curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health != "up") | "\(.scrapePool) \(.scrapeUrl) \(.lastError)"'
```

Nothing must print. A target with `context deadline exceeded` is a scrape that a policy drops: the pool name says which path (the services in `shop`, PostgreSQL and RabbitMQ in `data`, the kubelet and CoreDNS, or the stack's own pods). The fix is in the policy of the target's namespace for the ingress and in `prometheus-allow-to-*` for the egress.

### 5. Logs in Loki

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/loki 3100:3100
```

```bash
curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="shop"}' --data-urlencode 'limit=3' | jq '.data.result | length'
```

It must print a number above zero. If not, look at Alloy: `kubectl -n observability logs deploy/alloy -c alloy --tail=50`. Errors about the API server mean the `allow-kube-api-alloy` rule or the `vpcCidr` value; errors about pushing mean the `alloy-allow-to-loki` pair.

### 6. Traces reaching the Collector

Send a request through the gateway (from your own terminal, using a port-forward to the gateway), then look at the Collector's counters:

```bash
kubectl --context <EKS_CONTEXT> -n shop port-forward svc/gateway 8080:8080
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/healthz
```

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/otel-collector 8888:8888
curl -s http://localhost:8888/metrics | grep -E '^otelcol_(receiver_accepted_spans|exporter_sent_spans)'
```

The accepted count rises when a request creates spans, and the exported count rises after it (the Collector exports to Tempo). Accepted staying at zero is a blocked `shop` to Collector path (the `<service>-allow-collector` and `collector-allow-from-services` pair); accepted rising but exported not is the Collector to Tempo pair.

### 7. Argo CD

```bash
kubectl --context <EKS_CONTEXT> -n argocd get applications
```

Every Application must be `Synced` and `Healthy`, including the policy Applications. A policy Application that is `Degraded` with a `vpcCidr` message is a missing annotation (step 2 of the apply).

## See what is being dropped

- **The agent's own log on each node.** `kubectl -n kube-system logs -l k8s-app=aws-node -c aws-network-policy-agent --tail=100` (the container name is the one the add-on adds; check it with `kubectl -n kube-system get pod -l k8s-app=aws-node -o jsonpath='{.items[0].spec.containers[*].name}'`). It shows start-up and errors in programming policies.
- **The node's file.** `/var/log/aws-routed-eni/network-policy-agent.log` on the node, for example through an SSM session (the node role has the managed SSM policy). The aws-node log is next to it, `/var/log/aws-routed-eni/ipamd.log`.
- **Policy event logs.** The agent can log one line for each connection it accepts or denies. In the add-on's configuration they are the setting `enablePolicyEventLogs` in the `nodeAgent` section (and `enableCloudWatchLogs` to ship them). This module does not set them. Look at the schema for your add-on version before you rely on the names: `aws eks describe-addon-configuration --addon-name vpc-cni --addon-version <VERSION> --query configurationSchema --output text`. Adding it is a Terraform change to the add-on's configuration values; the policy event logs are verbose, so turn them off again.
- **Which policies select a pod.** `kubectl -n <ns> get networkpolicy` and `kubectl -n <ns> describe networkpolicy <name>`. A pod is isolated for ingress when any policy selects it and lists `Ingress`.
- **The offline answer.** `./scripts/network-policies-check.sh` evaluates the flows against the rendered policies. When a connection is blocked, add the flow to [the matrix](../../scripts/tests/fixtures/network-policies/flows.yaml) as allowed: the check then names the side that blocks it.

## Roll back

In order of speed. Use the first that is enough.

1. **Delete the single policy that blocks.** `kubectl -n <ns> delete networkpolicy <name>` takes effect at once. Argo CD self-heal puts it back within minutes unless the Application's automation is paused, so pause it first: the Application's name is in `kubectl -n argocd get applications`, and the supported way is to turn off automated sync for it in the ApplicationSet (a change in Git). Argo CD versions that support the annotation `argocd.argoproj.io/skip-reconcile: "true"` on an Application stop reconciling it; check that your version does, and that the ApplicationSet controller does not overwrite the annotation.
2. **Turn the policies off through Argo CD, in Git.** For the services chart set `networkPolicy.enabled: false` (in `deploy/helm/service/values.yaml`, or in one service's values file to keep the others). For the platform charts set `enabled: false` in `platform/data/network-policies/values.yaml` or `platform/observability/network-policies/values.yaml`. The chart then renders nothing and Argo CD prunes the policies. The pods are open again as soon as the policies are gone.
3. **The add-on switch in Terraform, as the last resort.** `enable_network_policy = false` and `terraform apply` stop the enforcement for the whole cluster, in every namespace, including ones that are not ours. The policies stay in the cluster and are ignored.

After a rollback, find out which path was missing and add it (see below) before turning the policies on again.

## An operator cannot reach its instances

The operators' ports are the part of the design that came from documentation, not from a run. The first suspects:

- **CloudNativePG** (`cnpg-system`) to the PostgreSQL pods on **8000** (the instance status endpoint) and **5432**. Symptom: the `Cluster` stays in a non-healthy state, its status shows instances that cannot be reached, and the operator log (`kubectl -n cnpg-system logs deploy/data-cnpg-operator-cloudnative-pg`) shows connection timeouts to a pod address. The policy is `postgres-allow-from-operator`.
- **The RabbitMQ Cluster Operator** (`rabbitmq-system`) to the broker pods on **15672** and **5672**. Symptom: the `RabbitmqCluster` does not report `AllReplicasReady`, and the operator log (`kubectl -n rabbitmq-system logs deploy/rabbitmq-cluster-operator`) shows timeouts. The policy is `rabbitmq-allow-from-operator`.
- **The Prometheus Operator** to Prometheus and Alertmanager on 9090, 9093 and 8080. Symptom: the Prometheus or Alertmanager resource does not become available, and the operator log shows timeouts. The paths are `operator-allow-to-prometheus` and `operator-allow-to-alertmanager`.

Find the port in the operator's log, add it to the policy (and a row to the matrix), and apply through Git. As a stop-gap, delete the policy as in the first rollback step.

## Add a service or a new allow

1. **A new service in the shop.** Add `networkPolicy.ingressFrom` (who calls it), `egressTo` (the shop services it calls) and `egressToData` (any of `postgres`, `valkey`, `rabbitmq`) to its values file and its profile files, and its port to `networkPolicy.services` in `deploy/helm/service/values.yaml`. A new data target goes under `networkPolicy.dataTargets` with its labels and port. The destination writes its own ingress: add the new caller to `ingressFrom` of each service it calls.
2. **A new path in the data layer or observability.** For observability add a row to `flows` in the chart's values (it renders both halves); for data add a policy to the template of the component. A path to another namespace is written on both sides.
3. **The matrix.** Add an allowed row for the new path and a denied row for the nearest path that must stay closed. A pod that an operator creates is declared under `pods` with the place its labels come from. See the [fixtures README](../../scripts/tests/fixtures/network-policies/README.md).
4. **Run the checks.** `make network-policies-check` renders everything and fails with the flow, the direction and the side that blocks or wrongly allows it; `make deploy-check` and `make observability-check` check the charts. A label in a policy that no pod carries fails the check, so a typo cannot select nothing silently.
5. **Never open a range wider than the VPC range** and never leave `ports` out. The contract check refuses both.
