# Network policies: apply, check, debug and roll back

For someone applying the policies for the first time, and for someone debugging a blocked connection. What the policies are and why is in [ADR-0024](../adr/0024-network-policies.md). The policies of the `shop` namespace are in the [service chart](../../deploy/helm/README.md#network-policies), those of `data` in [`platform/data/network-policies`](../../platform/data/network-policies) and those of `observability` in [`platform/observability/network-policies`](../../platform/observability/network-policies).

**What has and has not run on a cluster.** On 2026-11-02 the first version of the policies ran on a real EKS cluster (Kubernetes 1.37, the VPC CNI add-on with `enableNetworkPolicy`), which was torn down afterwards. That version could not reach the API server and could not use a Service from a pod selector, because the policy agent matches egress against the Service address (see [ADR-0024](../adr/0024-network-policies.md#what-has-been-exercised)). With a rule for the Service range added by hand in each namespace the platform was healthy: all four services ready, 34 of 34 Prometheus targets up, a traced order across the four services, and DNS resolved in shop, data and observability. The ingress policies held with that rule: orders reached PostgreSQL and the gateway did not.

**The policies of this version have not been applied to a cluster yet.** They put the Service range in every egress rule, and take it from Terraform (`service_cidr_block`) through the annotation `platform.example/service-cidr`. The commands below were run against the first version, except where they say otherwise. The first things to check on the next apply are DNS, then the API server.

## Apply

The order matters, and each step has a way to see that it worked.

1. **Terraform first: the add-on and the Service range.** `terraform apply` in `infra/terraform/environments/aws` sets `enableNetworkPolicy` on the `vpc-cni` add-on (`enable_network_policy`, default true) and gives the new output `service_cidr_block`, the address range of the cluster's Services. See [network policy enforcement](aws-eks.md#network-policy-enforcement) for the update of an existing cluster. Wait until the `aws-node` DaemonSet is fully rolled out and each pod has the `aws-network-policy-agent` container.
2. **The bootstrap script, again, after Terraform.** It writes two annotations on the cluster Secret: `platform.example/vpc-cidr`, from the output `vpc_cidr_block`, and `platform.example/service-cidr`, from the output `service_cidr_block`. It stops if either output is empty. Repeat the flags you already use (the script writes every label on each run).

   ```bash
   ./scripts/bootstrap-argocd.sh --context <EKS_CONTEXT> --enable-data --enable-observability --enable-apps --apps-profile data
   ```

   Until the annotations exist, the two policy Applications (`data-network-policies-*` and `observability-network-policies-*`) and the four service Applications (`apps-gateway-*`, `apps-orders-*`, `apps-payments-*`, `apps-notifier-*`) fail to sync, with a message that says `serviceCidr`, `networkPolicy.serviceCidr` or `vpcCidr` must be set. That is intended: a deny must not land without the rules for DNS and the API server. The charts need the Service range everywhere and the VPC range in `observability` only.
3. **Argo CD syncs the policies.** The service policies come with the services (wave 20 to 22), the data policies at wave 9 and the observability policies at wave 17. In each Application the allow rules go first (sync wave -2) and the default deny after them (wave -1).
4. **Check, in this order** (below). Stop at the first class that fails.

## Check after an apply

The probes use an ephemeral container, because the service images have no shell and an ephemeral container shares the pod's network namespace, so it is subject to the pod's own policies: it tests the real path. Nothing is installed on the pod, and the container disappears with the pod.

The debug image is busybox 1.37, pinned by digest. The digest below was read from the registry on 2026-11-01 (`docker buildx imagetools inspect busybox:1.37`; it is the digest of the multi-architecture index). Read it again before you rely on it, and replace it when you move to another version:

```bash
export DEBUG_IMAGE='docker.io/library/busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
```

The `shop` and `observability` namespaces enforce the restricted Pod Security level, and `data` the baseline level. Both apply to ephemeral containers. Two things are needed so that the container is accepted:

- **`--profile=restricted` on the `kubectl debug` command.** kubectl's default profile adds the `SYS_PTRACE` capability, which both levels reject, and the custom file cannot remove a capability that the profile added. This was found on the cluster of 2026-11-02, and the command below is the form that worked there.
- **A non-root user.** busybox runs as root by default, so this file gives the container a user and drops its capabilities (`kubectl debug --custom` needs kubectl 1.27 or later):

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
  kubectl --context <EKS_CONTEXT> -n "$ns" debug -it "$pod" --image="$DEBUG_IMAGE" --profile=restricted --custom=/tmp/debug-container.json -q -- "$@"
}
```

The attach step may print a warning and fall back to streaming the container's logs. The output of the command still arrives, and the warning is harmless.

Each call adds an ephemeral container to the pod (they cannot be removed). Reuse one with `kubectl attach` if you probe the same pod many times. Remove the file when you are done.

A probe that prints `closed` proves nothing until a probe of the same kind has printed `OPEN` from a pod that is allowed. Run the positive control first (see the data layer below), so that a broken probe is not mistaken for a working deny.

### 1. DNS first

DNS is the canary. Every other path starts with a name lookup. It is also where the policy agent's behaviour shows: the agent matches egress against the Service address, and the cluster DNS is a Service. The policies of this version allow DNS to the Service range and to the DNS pods (on 53, UDP and TCP), so this is the first check of that rule.

```bash
probe shop app.kubernetes.io/name=orders nslookup kubernetes.default.svc.cluster.local
probe data cnpg.io/cluster=platform-pg nslookup kubernetes.default.svc.cluster.local
probe observability app.kubernetes.io/name=grafana nslookup kubernetes.default.svc.cluster.local
```

All three must print an address. If one times out:

- **Check the Service range.** The annotation `platform.example/service-cidr` on the cluster Secret must be the range that contains the cluster IP of the Service `kubernetes` (`kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'`). On an EKS cluster with the default range this is `172.20.0.0/16`; that is an example, not a value in this repository. The `nameserver` in `/etc/resolv.conf` of the pod is the cluster DNS Service and must be inside the range too.
- **Look at the policy of the pod:** `kubectl -n <ns> get networkpolicy`, then `kubectl -n <ns> describe networkpolicy <service>-allow-dns` (`allow-dns` in `data` and `observability`). It must have two peers, the DNS pods and an `ipBlock` with the Service range, on UDP and TCP 53. A rule with the pod selector only is the first version of the policies, and it is the cause of this symptom: the agent matches the Service address of the DNS, so the connection is dropped.
- **Tell the two apart** by looking the name up through a DNS pod directly. Get a pod address with `kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide`, then `probe shop app.kubernetes.io/name=orders nslookup kubernetes.default.svc.cluster.local <COREDNS_POD_IP>`. If that works and the lookup through the `nameserver` does not, the Service range is missing from the rule.
- If both fail, a policy is blocking more than DNS: see the drops (below).

The same applies to every connection through a Service. If a path fails, check that the egress policy of the source has the Service range on that port next to the pod selector.

### 2. The request path

```bash
probe shop app.kubernetes.io/name=gateway wget -q -O- -T 3 http://orders:8081/readyz
probe shop app.kubernetes.io/name=gateway wget -q -O- -T 3 http://payments:8082/readyz
probe shop app.kubernetes.io/name=orders wget -q -O- -T 3 http://payments:8082/readyz
```

Each must print a small JSON document. The gateway has no shell either, so it is the ephemeral container that opens the connection, with the gateway's policies. Then paths that must be closed (each prints `closed` after three seconds). The three requests above are the positive control for these:

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

Now the deny, with its positive control. The same command runs from a pod that is allowed and from one that is not. Run the first and read it first:

```bash
probe shop app.kubernetes.io/name=orders sh -c 'nc -w 3 platform-pg-rw.data.svc 5432 </dev/null && echo OPEN || echo closed'
probe shop app.kubernetes.io/name=gateway sh -c 'nc -w 3 platform-pg-rw.data.svc 5432 </dev/null && echo OPEN || echo closed'
```

The first must print `OPEN` and the second `closed`. If the first prints `closed`, the probe is broken or the allowed path is blocked, and the second result means nothing. On the cluster of 2026-11-02, with the Service range allowed by hand, this was the result: the orders pod reached PostgreSQL and the gateway pod did not. So the ingress policy of PostgreSQL decides who may connect, even when the source may open the port to the Service range.

Then confirm the real services are healthy, since that exercises the same paths with the real clients: `kubectl -n shop get pods` (all ready; the data profile's `/readyz` needs the database and the broker), and the migration Jobs completed.

The operators: `kubectl -n data get cluster platform-pg` shows `Cluster in healthy state`, and `kubectl -n data get rabbitmqcluster platform-mq` shows `AllReplicasReady` true. If an operator cannot reach its instances, see [the operators](#an-operator-cannot-reach-its-instances).

### 4. Prometheus targets

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In another terminal:

```bash
curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health != "up") | "\(.scrapePool) \(.scrapeUrl) \(.lastError)"'
```

Nothing must print. A target with `context deadline exceeded` is a scrape that a policy drops: the pool name says which path (the services in `shop`, PostgreSQL and RabbitMQ in `data`, the kubelet and CoreDNS, or the stack's own pods). The fix is in the policy of the target's namespace for the ingress and in `prometheus-allow-to-*` for the egress. Prometheus reaches the kubelets and the API server addresses through the VPC range (`prometheus-allow-to-kubelets` and `prometheus-allow-to-apiserver-endpoints`), so a wrong `vpc-cidr` annotation shows as those targets being down. On the cluster of 2026-11-02 all 34 targets were up with the temporary rule.

### 5. Logs in Loki

```bash
kubectl --context <EKS_CONTEXT> -n observability port-forward svc/loki 3100:3100
```

```bash
curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="shop"}' --data-urlencode 'limit=3' | jq '.data.result | length'
```

It must print a number above zero. If not, look at Alloy: `kubectl -n observability logs deploy/alloy -c alloy --tail=50`. Errors about the API server mean the `allow-kube-api-alloy` rule (TCP 443 to the Service range) or the `serviceCidr` value; errors about pushing mean the `alloy-allow-to-loki` pair.

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

Every Application must be `Synced` and `Healthy`, including the policy Applications. A policy or service Application that is `Degraded` with a `serviceCidr`, `networkPolicy.serviceCidr` or `vpcCidr` message is a missing annotation (step 2 of the apply).

## See what is being dropped

- **The agent's own log on each node.** `kubectl -n kube-system logs -l k8s-app=aws-node -c aws-network-policy-agent --tail=100` (the container name is the one the add-on adds; check it with `kubectl -n kube-system get pod -l k8s-app=aws-node -o jsonpath='{.items[0].spec.containers[*].name}'`). It shows start-up and errors in programming policies.
- **The node's file.** `/var/log/aws-routed-eni/network-policy-agent.log` on the node, for example through an SSM session (the node role has the managed SSM policy). The aws-node log is next to it, `/var/log/aws-routed-eni/ipamd.log`.
- **Policy event logs.** The agent can log one line for each connection it accepts or denies. In the add-on's configuration they are the setting `enablePolicyEventLogs` in the `nodeAgent` section (and `enableCloudWatchLogs` to ship them). This module does not set them. Look at the schema for your add-on version before you rely on the names: `aws eks describe-addon-configuration --addon-name vpc-cni --addon-version <VERSION> --query configurationSchema --output text`. Adding it is a Terraform change to the add-on's configuration values; the policy event logs are verbose, so turn them off again.
- **A connection through a Service is matched on its ClusterIP.** If a probe or the agent's log shows a drop for a Service, look at the egress policy of the source for the Service range on that port; the pod selector does not apply to it.
- **Which policies select a pod.** `kubectl -n <ns> get networkpolicy` and `kubectl -n <ns> describe networkpolicy <name>`. A pod is isolated for ingress when any policy selects it and lists `Ingress`.
- **The offline answer.** `./scripts/network-policies-check.sh` evaluates the flows against the rendered policies. When a connection is blocked, add the flow to [the matrix](../../scripts/tests/fixtures/network-policies/flows.yaml) as allowed: the check then names the side that blocks it.

## Roll back

In order of speed. Use the first that is enough.

1. **Delete the single policy that blocks.** `kubectl -n <ns> delete networkpolicy <name>` takes effect at once. Argo CD self-heal puts it back within minutes unless the Application's automation is paused, so pause it first: the Application's name is in `kubectl -n argocd get applications`, and the supported way is to turn off automated sync for it in the ApplicationSet (a change in Git). Argo CD versions that support the annotation `argocd.argoproj.io/skip-reconcile: "true"` on an Application stop reconciling it; check that your version does, and that the ApplicationSet controller does not overwrite the annotation.
2. **Turn the policies off through Argo CD, in Git.** For the services chart set `networkPolicy.enabled: false` (in `deploy/helm/service/values.yaml`, or in one service's values file to keep the others). For the platform charts set `enabled: false` in `platform/data/network-policies/values.yaml` or `platform/observability/network-policies/values.yaml`. The chart then renders nothing and Argo CD prunes the policies. The pods are open again as soon as the policies are gone.
3. **The add-on switch in Terraform, as the last resort.** `enable_network_policy = false` and `terraform apply` stop the enforcement for the whole cluster, in every namespace, including ones that are not ours. The policies stay in the cluster and are ignored.

After a rollback, find out which path was missing and add it (see below) before turning the policies on again.

## An operator cannot reach its instances

The operators' ports are the part of the design that came from documentation, not from a run. The operator namespaces have no policies of their own; the paths below are the ingress to their instances. The first suspects:

- **CloudNativePG** (`cnpg-system`) to the PostgreSQL pods on **8000** (the instance status endpoint) and **5432**. Symptom: the `Cluster` stays in a non-healthy state, its status shows instances that cannot be reached, and the operator log (`kubectl -n cnpg-system logs deploy/data-cnpg-operator-cloudnative-pg`) shows connection timeouts to a pod address. The policy is `postgres-allow-from-operator`.
- **The RabbitMQ Cluster Operator** (`rabbitmq-system`) to the broker pods on **15672** and **5672**. Symptom: the `RabbitmqCluster` does not report `AllReplicasReady`, and the operator log (`kubectl -n rabbitmq-system logs deploy/rabbitmq-cluster-operator`) shows timeouts. The policy is `rabbitmq-allow-from-operator`.
- **The Prometheus Operator** to Prometheus and Alertmanager on 9090, 9093 and 8080. Symptom: the Prometheus or Alertmanager resource does not become available, and the operator log shows timeouts. The paths are `operator-allow-to-prometheus` and `operator-allow-to-alertmanager`.

Find the port in the operator's log, add it to the policy (and a row to the matrix), and apply through Git. As a stop-gap, delete the policy as in the first rollback step.

## Add a service or a new allow

1. **A new service in the shop.** Add `networkPolicy.ingressFrom` (who calls it), `egressTo` (the shop services it calls) and `egressToData` (any of `postgres`, `valkey`, `rabbitmq`) to its values file and its profile files, and its port to `networkPolicy.services` in `deploy/helm/service/values.yaml`. A new data target goes under `networkPolicy.dataTargets` with its labels and port. The destination writes its own ingress: add the new caller to `ingressFrom` of each service it calls.
2. **A new path in the data layer or observability.** For observability add a row to `flows` in the chart's values (it renders both halves); for data add a policy to the template of the component. A path to another namespace is written on both sides.
3. **The matrix.** Add an allowed row for the new path and a denied row for the nearest path that must stay closed. A pod that an operator creates is declared under `pods` with the place its labels come from. See the [fixtures README](../../scripts/tests/fixtures/network-policies/README.md).
4. **Run the checks.** `make network-policies-check` renders everything and fails with the flow, the direction and the side that blocks or wrongly allows it; `make deploy-check` and `make observability-check` check the charts. A label in a policy that no pod carries fails the check, so a typo cannot select nothing silently.
5. **Never open the Service range or the VPC range on a port the workload does not need,** never open a range of `/0`, and never leave `ports` out. The contract check refuses the last two, and the matrix has denied flows for the first (a destination that must refuse a port that its sources may open to the Service range).
