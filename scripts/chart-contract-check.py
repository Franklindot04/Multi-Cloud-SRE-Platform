#!/usr/bin/env python3
"""Contract checks for the data layer charts and the Argo CD ordering.

These catch the failures seen when the data layer first ran on a real cluster, none of which a schema check or
a successful `helm template` reveals:

  hooks LABEL         a chart that renders only hook resources. Argo CD compares the live state with the
                      non-hook resources; with none, the Application is Synced and Healthy without ever
                      running a sync, so its hooks never run.
  secret-jobs LABEL   a Job that creates Secrets (it can create or patch Secrets through its service account,
                      or its script posts to the Secrets API) is annotated as a Helm hook. An Argo CD hook is
                      allowed. Helm hooks are translated by Argo CD and do not run when the chart has nothing
                      else to sync.
  postgres-gate LABEL the PostgreSQL chart renders a Cluster whose managed roles use password Secrets, and a
                      PreSync gate Job that waits for every one of them, with a Role that can read them.
  waves APPS_DIR README
                      the sync-wave ordering of the data and observability ApplicationSets is the documented
                      one: secrets before postgres, valkey and rabbitmq; the credential copy after rabbitmq;
                      operators before what they run; the Grafana secret and the Prometheus Operator CRDs before
                      what needs them; every wave agrees with the table in the README.

The observability charts (platform/observability) add checks on the rendered output:

  restricted LABEL    every pod template (and the Prometheus resource, whose pods the operator creates) meets the
                      restricted Pod Security level that the observability namespace enforces: no host namespaces,
                      host ports or hostPath, no privileged container, privilege escalation off, all capabilities
                      dropped, a non-root user and a seccomp profile
  ephemeral LABEL     the default profile has no persistent storage and no way in: no PersistentVolumeClaim, volume
                      claim template or Prometheus or Alertmanager storage, no Ingress, no LoadBalancer or
                      NodePort Service
  grafana-admin LABEL Grafana reads its admin account from the Secret grafana-admin and no password is set in the
                      rendered output
  digest-pinned LABEL every container image is pinned by digest
  dashboards LABEL DIR STACK_VALUES SOURCE...
                      every Grafana dashboard in DIR is valid JSON with a unique uid (the file name) and title, uses
                      a data source variable (datasource for Prometheus, loki for Loki) and no fixed data source uid,
                      and uses only metric names that are confirmed in a SOURCE (a source directory, a vendored chart
                      tarball, a list of names, or rendered rules: the record and alert names of its PrometheusRules). LogQL queries may use only the log stream labels (namespace, pod,
                      container, app, service, service_name) and the level, and every selector must exclude the empty
                      value, as Loki requires. The
                      rendered ConfigMaps (stdin) carry the label that the Grafana sidecar in STACK_VALUES selects
  loki LABEL          the Loki configuration is single tenant, uses the TSDB index with schema v13 and the filesystem,
                      has the compactor's retention on with a retention period of at most 168h, and sets ingestion and
                      line size limits
  tempo LABEL         the Tempo configuration is single tenant, stores traces on the local filesystem, deletes them after
                      at most 72h, receives only OTLP (no Jaeger, Zipkin or OpenCensus receiver), has no metrics generator
                      and sends no usage report
  alertmanager LABEL  Alertmanager is on with one replica and resource requests and limits, Prometheus sends its alerts to
                      it, its configuration routes severity page to the receiver page and severity ticket to the
                      receiver ticket (everything else to default), groups by alertname, slo and service, has the two
                      inhibitions (a page alert hides the ticket alerts of the same slo and service; ServiceTargetDown
                      hides the burn-rate alerts of the same service), and its receivers are empty: no URL, token or
                      password is rendered anywhere in the configuration
  grafana-datasources LABEL
                      the data sources Grafana provisions (the ConfigMap with the label grafana_datasource) are the
                      Prometheus, Alertmanager, Loki and Tempo ones with unique uids; the Loki derived field links to Tempo by uid and
                      its regular expression finds the trace id in a request log line in the format each service
                      writes and in no other; the Tempo trace-to-logs link points at Loki by uid with a time shift on
                      both sides and a query that uses the trace id; no service graph or node graph is turned on
  alloy LABEL         the Alloy configuration reads logs only with loki.source.kubernetes (no file or CRD source), from
                      exactly the namespaces data and shop, turns no part of a log line into a label (the level goes
                      to structured metadata), and its role cannot read Secrets or ConfigMaps
  crds LABEL APPSET   the Prometheus Operator CRDs are rendered and well formed (kubeconform has no schema for the
                      CustomResourceDefinition kind, so this is the check on them): the CRDs the platform relies on
                      exist, each has one storage version and a schema, and, because the large ones exceed what
                      client-side apply can store in an annotation, the ApplicationSet that deploys the chart
                      syncs with ServerSideApply=true
  loki-queries DIR    prints, one per line (dashboard, panel, query type, query, tab separated), every Loki query of the
                      dashboards in DIR with the Grafana variables filled in, with "All" selected and with concrete
                      values; scripts/observability-check.sh runs them against a Loki image
  slo-rules LABEL SOURCE...
                      the PrometheusRule "slo" holds, for every SLO, the recording rules the burn-rate alerts need (the
                      objective, the error budget, the error ratio over 5m, 30m, 1h, 2h, 6h, 1d, 3d and 30d, and the number
                      of events over 1h, 6h, 1d and 3d), named slo:<what>:<unit>[_<window>] with the labels slo and service;
                      objective + budget = 1; the four alerts per SLO (page 14.4x over 1h and 5m, page 6x over 6h and 30m,
                      ticket 3x over 1d and 2h, ticket 1x over 3d and 6h) use exactly those windows and burn rates and have
                      the minimum-event guard, a severity, the service label (and the slo label for burn rates), a summary, a description and a
                      runbook_url that ends in docs/runbooks/alerts.md#<anchor>; the rules use only metric names confirmed
                      in a SOURCE (service code), leave the operational routes out of every gateway HTTP selector, leave
                      client errors out of the availability SLI, and use a histogram threshold (le) that is a bucket
                      boundary of the services' histogram
  project-fit LABEL PROJECT DEFAULT_NAMESPACE
                      every rendered resource is allowed by the AppProject file: its kind, and its namespace
                      (DEFAULT_NAMESPACE where the manifest names none)

The per-chart checks read a multi-document YAML stream (the output of `helm template`) on stdin.

Usage: helm template ... | chart-contract-check.py hooks|secret-jobs|postgres-gate|restricted|ephemeral|grafana-admin|digest-pinned|loki|tempo|alertmanager|grafana-datasources|alloy LABEL
       helm template ... | chart-contract-check.py project-fit LABEL PROJECT_FILE DEFAULT_NAMESPACE
       helm template ... --include-crds | chart-contract-check.py crds LABEL APPLICATIONSET_FILE
       helm template ... | chart-contract-check.py dashboards LABEL DASHBOARD_DIR STACK_VALUES SOURCE...
       helm template ... | chart-contract-check.py slo-rules LABEL SOURCE...
       chart-contract-check.py waves platform/argocd/apps platform/argocd/README.md
"""

import base64
import glob
import json
import os
import re
import sys
import tarfile

import yaml

# A bare "=" in a CRD (an enum value) is the YAML 1.1 "value" tag, which PyYAML cannot construct. Read it as text.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

HELM_HOOK = "helm.sh/hook"
ARGO_HOOK = "argocd.argoproj.io/hook"
WAVE = "argocd.argoproj.io/sync-wave"
WRITE_VERBS = {"create", "patch", "update", "*"}


def annotations(doc):
    return (doc.get("metadata") or {}).get("annotations") or {}


def name_of(doc):
    return "{}/{}".format(doc.get("kind", "?"), (doc.get("metadata") or {}).get("name", "?"))


def is_hook(doc):
    ann = annotations(doc)
    return HELM_HOOK in ann or ARGO_HOOK in ann


def load_stdin():
    return [d for d in yaml.safe_load_all(sys.stdin) if isinstance(d, dict) and d.get("kind")]


def pod_template(job):
    return ((job.get("spec") or {}).get("template") or {}).get("spec") or {}


def script_text(job):
    parts = []
    for c in pod_template(job).get("containers", []):
        parts.extend(str(x) for x in (c.get("command") or []))
        parts.extend(str(x) for x in (c.get("args") or []))
    return "\n".join(parts)


def creates_secrets(job, docs):
    """True if the Job's service account may write Secrets, or its script calls the Secrets API to write."""
    sa = pod_template(job).get("serviceAccountName", "default")
    ns = (job.get("metadata") or {}).get("namespace")
    roles = {}
    for d in docs:
        if d["kind"] in ("Role", "ClusterRole"):
            roles[(d["kind"], (d.get("metadata") or {}).get("namespace"), d["metadata"]["name"])] = d
    for d in docs:
        if d["kind"] not in ("RoleBinding", "ClusterRoleBinding"):
            continue
        bound = any(
            s.get("kind") == "ServiceAccount" and s.get("name") == sa and s.get("namespace", ns) == ns
            for s in d.get("subjects") or []
        )
        if not bound:
            continue
        ref = d["roleRef"]
        key = (ref["kind"], (d.get("metadata") or {}).get("namespace") if ref["kind"] == "Role" else None, ref["name"])
        role = roles.get(key)
        for rule in (role or {}).get("rules") or []:
            if "secrets" in (rule.get("resources") or []) and WRITE_VERBS & set(rule.get("verbs") or []):
                return True
    text = script_text(job)
    return bool(re.search(r"secrets", text) and re.search(r"-X +POST|kubectl +(create|apply)|--request +POST", text))


def check_hooks(docs, label):
    regular = [d for d in docs if not is_hook(d)]
    if regular:
        return []
    return [
        "{}: the chart renders only hook resources ({}). Argo CD has nothing to compare, reports the "
        "Application Synced and Healthy without a sync, and the hooks never run. Add at least one "
        "ordinary resource (for example the RBAC objects) so the Application syncs.".format(
            label, ", ".join(sorted(name_of(d) for d in docs)) or "nothing at all"
        )
    ]


def check_secret_jobs(docs, label):
    problems = []
    for d in docs:
        if d["kind"] != "Job" or HELM_HOOK not in annotations(d):
            continue
        if creates_secrets(d, docs):
            problems.append(
                "{}: {} creates Secrets and is a Helm hook ({}). Use an Argo CD hook ({}: Sync or PreSync) "
                "with ordinary RBAC resources in the chart.".format(label, name_of(d), annotations(d)[HELM_HOOK], ARGO_HOOK)
            )
    return problems


def check_postgres_gate(docs, label):
    problems = []
    clusters = [d for d in docs if d["kind"] == "Cluster" and str(d.get("apiVersion", "")).startswith("postgresql.cnpg.io/")]
    if not clusters:
        return ["{}: no CloudNativePG Cluster rendered".format(label)]
    secrets = set()
    for c in clusters:
        for role in ((c.get("spec") or {}).get("managed") or {}).get("roles") or []:
            ref = (role.get("passwordSecret") or {}).get("name")
            if ref:
                secrets.add(ref)
    if not secrets:
        problems.append("{}: the Cluster has no managed role with a passwordSecret; the gate has nothing to wait for".format(label))
    gates = [
        d
        for d in docs
        if d["kind"] == "Job" and "PreSync" in annotations(d).get(ARGO_HOOK, "").replace(" ", "").split(",")
    ]
    if not gates:
        return problems + [
            "{}: the chart has no PreSync gate Job. Without it the Cluster is applied before the role Secrets "
            "exist and the managed roles stay pending-reconciliation (ADR-0018).".format(label)
        ]
    gate = gates[0]
    text = script_text(gate)
    for s in sorted(secrets):
        if s not in text:
            problems.append("{}: the gate {} does not wait for Secret {}".format(label, name_of(gate), s))
    readable = set()
    for d in docs:
        if d["kind"] == "Role":
            for rule in d.get("rules") or []:
                if "secrets" in (rule.get("resources") or []) and "get" in (rule.get("verbs") or []):
                    readable.update(rule.get("resourceNames") or [])
    for s in sorted(secrets - readable):
        problems.append("{}: no Role lets the gate read Secret {}".format(label, s))
    return problems


WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "Pod", "CronJob")
CLUSTER_SCOPED = {
    "Namespace",
    "CustomResourceDefinition",
    "ClusterRole",
    "ClusterRoleBinding",
    "PersistentVolume",
    "StorageClass",
    "PriorityClass",
    "APIService",
    "MutatingWebhookConfiguration",
    "ValidatingWebhookConfiguration",
    "IngressClass",
    "ClusterIssuer",
    "IngressClassParams",
}
# Volume types the restricted Pod Security level allows.
RESTRICTED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"}


def pod_specs(docs):
    """(name, pod spec, pod template metadata) for every workload in the stream."""
    for d in docs:
        kind = d["kind"]
        if kind not in WORKLOAD_KINDS:
            continue
        if kind == "Pod":
            yield name_of(d), d.get("spec") or {}, d.get("metadata") or {}
            continue
        spec = d.get("spec") or {}
        template = (spec.get("jobTemplate") or {}).get("spec", {}).get("template") if kind == "CronJob" else spec.get("template")
        template = template or {}
        yield name_of(d), template.get("spec") or {}, template.get("metadata") or {}


def check_restricted(docs, label):
    problems = []

    def fail(where, message):
        problems.append("{}: {} {}".format(label, where, message))

    for where, spec, _meta in pod_specs(docs):
        for flag in ("hostNetwork", "hostPID", "hostIPC"):
            if spec.get(flag):
                fail(where, "sets {}, which the restricted level does not allow".format(flag))
        for v in spec.get("volumes") or []:
            kinds = set(v) - {"name"}
            if not kinds <= RESTRICTED_VOLUMES:
                fail(where, "uses the volume type {} ({}), which the restricted level does not allow".format(
                    ", ".join(sorted(kinds - RESTRICTED_VOLUMES)), v.get("name")))
        pod_sc = spec.get("securityContext") or {}
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            sc = c.get("securityContext") or {}
            name = "container " + c.get("name", "?")
            for port in c.get("ports") or []:
                if port.get("hostPort"):
                    fail(where, "{} uses hostPort {}".format(name, port["hostPort"]))
            if sc.get("privileged"):
                fail(where, "{} is privileged".format(name))
            if sc.get("allowPrivilegeEscalation") is not False:
                fail(where, "{}: allowPrivilegeEscalation must be false".format(name))
            caps = sc.get("capabilities") or {}
            if "ALL" not in (caps.get("drop") or []):
                fail(where, "{} must drop ALL capabilities".format(name))
            if set(caps.get("add") or []) - {"NET_BIND_SERVICE"}:
                fail(where, "{} adds capabilities other than NET_BIND_SERVICE".format(name))
            if not (sc.get("runAsNonRoot") is True or pod_sc.get("runAsNonRoot") is True):
                fail(where, "{}: runAsNonRoot must be true".format(name))
            if sc.get("runAsUser", pod_sc.get("runAsUser")) == 0:
                fail(where, "{} runs as user 0".format(name))
            seccomp = (sc.get("seccompProfile") or pod_sc.get("seccompProfile") or {}).get("type")
            if seccomp not in ("RuntimeDefault", "Localhost"):
                fail(where, "{} needs a seccomp profile (RuntimeDefault)".format(name))
    # The pods of a Prometheus resource are created by the operator at run time and cannot be rendered. The pod
    # settings it is given are checked here; the container settings the operator adds are not visible offline.
    for d in docs:
        if d["kind"] not in ("Prometheus", "Alertmanager"):
            continue
        spec = d.get("spec") or {}
        sc = spec.get("securityContext") or {}
        where = name_of(d)
        if sc.get("runAsNonRoot") is not True:
            fail(where, "securityContext.runAsNonRoot must be true")
        if (sc.get("seccompProfile") or {}).get("type") not in ("RuntimeDefault", "Localhost"):
            fail(where, "securityContext needs a seccomp profile (RuntimeDefault)")
        if spec.get("hostNetwork"):
            fail(where, "sets hostNetwork")
    return problems


def check_ephemeral(docs, label):
    problems = []
    for d in docs:
        where = name_of(d)
        if d["kind"] in ("PersistentVolumeClaim", "Ingress"):
            problems.append("{}: {} is rendered, which the default profile must not".format(label, where))
        if d["kind"] == "Service" and (d.get("spec") or {}).get("type") in ("LoadBalancer", "NodePort"):
            problems.append("{}: {} is a {} Service; access is by port-forward only".format(label, where, d["spec"]["type"]))
        if d["kind"] == "StatefulSet" and (d.get("spec") or {}).get("volumeClaimTemplates"):
            problems.append("{}: {} has volume claim templates".format(label, where))
        if d["kind"] in ("Prometheus", "Alertmanager") and (d.get("spec") or {}).get("storage"):
            problems.append("{}: {} has persistent storage configured; the default profile uses emptyDir".format(label, where))
    for where, spec, _meta in pod_specs(docs):
        for v in spec.get("volumes") or []:
            if "persistentVolumeClaim" in v:
                problems.append("{}: {} mounts the claim {}".format(label, where, v["persistentVolumeClaim"].get("claimName")))
    return problems


def check_grafana_admin(docs, label):
    problems = []
    deployments = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-grafana")]
    if not deployments:
        return ["{}: no Grafana Deployment rendered".format(label)]
    wanted = {"GF_SECURITY_ADMIN_USER": "admin-user", "GF_SECURITY_ADMIN_PASSWORD": "admin-password"}
    for dep in deployments:
        found = {}
        for c in dep["spec"]["template"]["spec"]["containers"]:
            for e in c.get("env") or []:
                if e["name"] in wanted:
                    found[e["name"]] = e
                if re.search(r"PASSWORD|SECRET", e["name"], re.I) and "value" in e:
                    problems.append("{}: {} sets {} to a literal value".format(label, name_of(dep), e["name"]))
        for var, key in sorted(wanted.items()):
            ref = ((found.get(var) or {}).get("valueFrom") or {}).get("secretKeyRef") or {}
            if ref.get("name") != "grafana-admin" or ref.get("key") != key:
                problems.append("{}: {} must read {} from the key {} of the Secret grafana-admin".format(label, name_of(dep), var, key))
    for d in docs:
        if d["kind"] == "Secret":
            data = dict(d.get("data") or {}, **(d.get("stringData") or {}))
            if any("password" in k.lower() for k in data):
                problems.append("{}: {} carries a password".format(label, name_of(d)))
    return problems


def check_digest_pinned(docs, label):
    problems = []
    for where, spec, _meta in pod_specs(docs):
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            if not re.search(r"@sha256:[0-9a-f]{64}$", str(c.get("image", ""))):
                problems.append("{}: {} container {} image {} is not pinned by digest".format(label, where, c.get("name"), c.get("image")))
    return problems


def _config_map(docs, name):
    for d in docs:
        if d["kind"] == "ConfigMap" and (d.get("metadata") or {}).get("name") == name:
            return d.get("data") or {}
    return None


def check_loki(docs, label):
    """The Loki configuration the chart renders: one tenant, TSDB schema v13, filesystem storage, retention on."""
    data = _config_map(docs, "loki")
    if data is None or "config.yaml" not in data:
        return ["{}: no ConfigMap loki with a config.yaml".format(label)]
    cfg = yaml.safe_load(data["config.yaml"]) or {}
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    if cfg.get("auth_enabled") is not False:
        fail("auth_enabled must be false (single tenant)")
    configs = (cfg.get("schema_config") or {}).get("configs") or []
    if not configs:
        fail("schema_config has no entry")
    else:
        newest = sorted(configs, key=lambda c: str(c.get("from")))[-1]
        if newest.get("store") != "tsdb" or newest.get("schema") != "v13":
            fail("the newest schema entry must be store tsdb, schema v13 (it is {}, {})".format(newest.get("store"), newest.get("schema")))
    if "filesystem" not in ((cfg.get("common") or {}).get("storage") or {}):
        fail("common.storage must be the filesystem; object storage needs a bucket and a role this profile does not have")
    if (cfg.get("compactor") or {}).get("retention_enabled") is not True:
        fail("compactor.retention_enabled must be true")
    limits = cfg.get("limits_config") or {}
    retention = str(limits.get("retention_period", ""))
    if not re.fullmatch(r"\d+h", retention) or int(retention[:-1]) > 168:
        fail("limits_config.retention_period must be set in hours and be at most 168h (it is '{}')".format(retention))
    for key in ("ingestion_rate_mb", "ingestion_burst_size_mb", "per_stream_rate_limit", "max_line_size"):
        if not limits.get(key):
            fail("limits_config.{} must be set".format(key))
    return problems


def check_tempo(docs, label):
    """The Tempo configuration the chart renders: one tenant, local storage, short retention, OTLP only."""
    data = _config_map(docs, "tempo")
    if data is None or "tempo.yaml" not in data:
        return ["{}: no ConfigMap tempo with a tempo.yaml".format(label)]
    cfg = yaml.safe_load(data["tempo.yaml"]) or {}
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    if cfg.get("multitenancy_enabled") is not False:
        fail("multitenancy_enabled must be false (single tenant)")
    backend = (((cfg.get("storage") or {}).get("trace")) or {}).get("backend")
    if backend != "local":
        fail("storage.trace.backend must be local; object storage needs a bucket and a role this profile does not have (it is {})".format(backend))
    retention = str((((cfg.get("compactor") or {}).get("compaction")) or {}).get("block_retention", ""))
    if not re.fullmatch(r"\d+h", retention) or int(retention[:-1]) > 72:
        fail("compactor.compaction.block_retention must be set in hours and be at most 72h (it is '{}')".format(retention))
    receivers = ((cfg.get("distributor") or {}).get("receivers")) or {}
    if sorted(receivers) != ["otlp"]:
        fail("the distributor must receive only otlp (it has {})".format(", ".join(sorted(receivers)) or "no receiver"))
    else:
        protocols = sorted((receivers["otlp"] or {}).get("protocols") or {})
        if protocols != ["grpc", "http"]:
            fail("the otlp receiver must have the protocols grpc and http (it has {})".format(", ".join(protocols) or "none"))
    if "metrics_generator" in cfg:
        fail("the metrics generator needs a remote-write endpoint and is off in this profile")
    if (cfg.get("usage_report") or {}).get("reporting_enabled") is not False:
        fail("usage_report.reporting_enabled must be false")
    return problems


# Request log lines in the format the services write (apps/README.md): one compact JSON object, the trace id as
# "trace_id" with 32 lower-case hex digits (the W3C trace id, which every service takes from the traceparent header or
# makes). Go (gateway, notifier), Python (orders) and Java (payments) differ in the timestamp and nothing else that
# matters here.
TRACE_ID_SAMPLES = [
    ("gateway", '{"timestamp":"2026-10-31T22:04:24.479+00:00","level":"info","message":"request","service":"gateway","request_id":"5de8b2f4-9a1d-4983-8621-f5139aa6aeb1","trace_id":"343160a1f0116b35eab91f1166aa2d76","method":"GET","route":"/readyz","status":200,"duration_ms":7.144}',
     "343160a1f0116b35eab91f1166aa2d76"),
    ("orders", '{"timestamp":"2026-10-31T22:04:24.947+00:00","level":"info","message":"request","service":"orders","request_id":"1a106aea-b94a-42c1-a62c-74e1e4bf3b28","trace_id":"4d882ad0c96aa04fd94d935e7fbc3a40","method":"GET","route":"/healthz","status":200,"duration_ms":0.566}',
     "4d882ad0c96aa04fd94d935e7fbc3a40"),
    ("payments", '{"timestamp":"2026-10-31T22:04:25.910Z","level":"info","message":"request","service":"payments","request_id":"70bbda7d-d590-4cf5-a9a5-da0c407e56ec","trace_id":"844318253e7de74d01eb0f1dddc41a7b","method":"GET","route":"/readyz","status":200,"duration_ms":1.21}',
     "844318253e7de74d01eb0f1dddc41a7b"),
]
# Lines that carry something like a trace id and must not match: the notifier's event line (a traceparent, not a
# trace_id), a short id, an upper-case id, a line with spaces after the colon (not what the services write) and a line
# with no trace at all (PostgreSQL).
TRACE_ID_NEGATIVES = [
    '{"level":"info","message":"event","request_id":"abc","traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}',
    '{"message":"request","trace_id":"4bf92f3577b34da6"}',
    '{"message":"request","trace_id":"4BF92F3577B34DA6A3CE929D0E0E4736"}',
    '{"message":"request", "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"}',
    '{"message":"request","trace_id":"4bf92f3577b34da6a3ce929d0e0e47360"}',
    "LOG:  checkpoint starting: time",
]


def _unescape(value):
    """Grafana's provisioning turns $$ into a dollar sign; the rendered file has the doubled form."""
    return str(value).replace("$$", "$")


AM_REQUIRED_INHIBITIONS = (
    # (source matchers, target matchers, equal labels)
    ({"severity = \"page\""}, {"severity = \"ticket\""}, ["slo", "service"]),
    ({"alertname = \"ServiceTargetDown\""}, {"alertname =~ \"SLOBurnRate.*\""}, ["service"]),
)
AM_SECRET_WORDS = re.compile(r"(?i)(url|token|password|secret|key|webhook|api_|routing_key|auth|smtp|http_config|_configs)")


def check_alertmanager(docs, label):
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    ams = [d for d in docs if d.get("kind") == "Alertmanager"]
    if len(ams) != 1:
        return ["{}: expected exactly one Alertmanager, found {}".format(label, len(ams))]
    am = ams[0]
    name = (am.get("metadata") or {}).get("name")
    spec = am.get("spec") or {}
    if spec.get("replicas") != 1:
        fail("the Alertmanager must have one replica (it has {})".format(spec.get("replicas")))
    res = spec.get("resources") or {}
    for kind in ("requests", "limits"):
        for resource in ("cpu", "memory"):
            if not (res.get(kind) or {}).get(resource):
                fail("the Alertmanager needs resources.{}.{}".format(kind, resource))
    if spec.get("listenLocal"):
        fail("the Alertmanager listens on localhost only, so Prometheus cannot reach it")
    if any(d.get("kind") == "Ingress" for d in docs):
        fail("an Ingress is rendered; access is by port-forward only")
    services = [d for d in docs if d.get("kind") == "Service" and (d.get("metadata") or {}).get("name") == name]
    if not services or (services[0].get("spec") or {}).get("type", "ClusterIP") != "ClusterIP":
        fail("the Alertmanager Service must exist and be a ClusterIP Service")

    # Prometheus sends its alerts to it.
    wired = False
    for d in docs:
        if d.get("kind") == "Prometheus":
            for target in ((d.get("spec") or {}).get("alerting") or {}).get("alertmanagers") or []:
                wired = wired or (target.get("name") == name and target.get("namespace") == (am.get("metadata") or {}).get("namespace"))
    if not wired:
        fail("Prometheus does not send alerts to the Alertmanager {} (spec.alerting.alertmanagers)".format(name))

    # The configuration is held in the Secret alertmanager-<name>.
    secrets = [d for d in docs if d.get("kind") == "Secret" and (d.get("metadata") or {}).get("name") == "alertmanager-" + name]
    if not secrets:
        return problems + ["{}: no Secret alertmanager-{} with the configuration".format(label, name)]
    raw = (secrets[0].get("data") or {}).get("alertmanager.yaml")
    text = base64.b64decode(raw).decode("utf-8") if raw else (secrets[0].get("stringData") or {}).get("alertmanager.yaml")
    if not text:
        return problems + ["{}: the Secret has no alertmanager.yaml".format(label)]
    config = yaml.safe_load(text)

    receivers = {r.get("name"): r for r in config.get("receivers") or []}
    for needed in ("default", "page", "ticket"):
        if needed not in receivers:
            fail("the configuration has no receiver {}".format(needed))
    for rname, receiver in receivers.items():
        extra = set(receiver) - {"name"}
        if extra:
            fail("the receiver {} is not empty (it has {}); a real receiver is added through a Secret, not in this file".format(rname, ", ".join(sorted(extra))))
    if AM_SECRET_WORDS.search(yaml.safe_dump(config.get("global") or {})):
        fail("the global section holds something that looks like a URL, token or password")

    route = config.get("route") or {}
    if route.get("receiver") != "default":
        fail("the root route must send to the receiver default (it sends to {})".format(route.get("receiver")))
    if route.get("group_by") != ["alertname", "slo", "service"]:
        fail("the root route must group by alertname, slo and service (it groups by {})".format(route.get("group_by")))
    for key in ("group_wait", "group_interval", "repeat_interval"):
        if not route.get(key):
            fail("the root route needs {}".format(key))
    by_severity = {}
    for child in route.get("routes") or []:
        for m in child.get("matchers") or []:
            mm = re.fullmatch(r'severity = "(\w+)"', m)
            if mm:
                by_severity[mm.group(1)] = child.get("receiver")
        if child.get("routes"):
            fail("a sub-route has routes of its own; the tree is meant to be two routes deep")
    for severity in ("page", "ticket"):
        if by_severity.get(severity) != severity:
            fail("severity {} must be routed to the receiver {} (it goes to {})".format(severity, severity, by_severity.get(severity)))
    if set(by_severity) - {"page", "ticket"}:
        fail("only the severities page and ticket have routes (found {})".format(", ".join(sorted(by_severity))))

    rules = config.get("inhibit_rules") or []
    for source, target, equal in AM_REQUIRED_INHIBITIONS:
        found = any(set(r.get("source_matchers") or []) == source and set(r.get("target_matchers") or []) == target and sorted(r.get("equal") or []) == sorted(equal) for r in rules)
        if not found:
            fail("the inhibition from {} to {} on {} is missing".format(sorted(source), sorted(target), equal))
    return problems


def check_grafana_datasources(docs, label):
    """The data sources Grafana provisions, and the links between Loki and Tempo."""
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    sources = []
    for d in docs:
        if d.get("kind") == "ConfigMap" and ((d.get("metadata") or {}).get("labels") or {}).get("grafana_datasource") == "1":
            for text in (d.get("data") or {}).values():
                sources.extend((yaml.safe_load(text) or {}).get("datasources") or [])
    if not sources:
        return ["{}: no ConfigMap with the label grafana_datasource and a datasources list".format(label)]
    by_uid = {}
    for s in sources:
        uid = s.get("uid")
        if not uid:
            fail("the data source {} has no fixed uid".format(s.get("name")))
        elif uid in by_uid:
            fail("the uid {} is used by two data sources".format(uid))
        by_uid[uid] = s
    for uid, kind in (("prometheus", "prometheus"), ("alertmanager", "alertmanager"), ("loki", "loki"), ("tempo", "tempo")):
        if uid not in by_uid:
            fail("no data source with the uid {}".format(uid))
        elif by_uid[uid].get("type") != kind:
            fail("the data source {} must be of type {} (it is {})".format(uid, kind, by_uid[uid].get("type")))
    if problems:
        return problems

    if ":9093" not in str(by_uid["alertmanager"].get("url", "")):
        fail("the Alertmanager data source must point at port 9093 of the Alertmanager Service (it is {})".format(by_uid["alertmanager"].get("url")))
    if (by_uid["alertmanager"].get("jsonData") or {}).get("handleGrafanaManagedAlerts"):
        fail("the Alertmanager data source must not handle Grafana-managed alerts: Grafana has no alerts of its own here")
    loki, tempo = by_uid["loki"], by_uid["tempo"]
    derived = (loki.get("jsonData") or {}).get("derivedFields") or []
    if len(derived) != 1:
        fail("the Loki data source must have exactly one derived field (it has {})".format(len(derived)))
    for field in derived:
        if field.get("name") != "trace_id":
            fail("the derived field must be named trace_id (it is {})".format(field.get("name")))
        target = by_uid.get(field.get("datasourceUid"))
        if target is None or target.get("type") != "tempo":
            fail("the derived field must link to the Tempo data source by its uid (it links to {})".format(field.get("datasourceUid")))
        if field.get("matcherType") != "regex":
            fail("the derived field must use matcherType regex (it is {})".format(field.get("matcherType")))
        if _unescape(field.get("url", "")) != "${__value.raw}":
            fail("the derived field url must be $${{__value.raw}} in the file, the value the regex captured (it is {})".format(field.get("url")))
        try:
            rx = re.compile(str(field.get("matcherRegex", "")))
        except re.error as e:
            fail("the derived field regular expression does not compile: {}".format(e))
            continue
        if rx.groups != 1:
            fail("the derived field regular expression must have exactly one group, the trace id (it has {})".format(rx.groups))
            continue
        for service, line, want in TRACE_ID_SAMPLES:
            m = rx.search(line)
            if not m or m.group(1) != want:
                fail("the derived field regular expression does not find the trace id in a {} log line".format(service))
        for line in TRACE_ID_NEGATIVES:
            if rx.search(line):
                fail("the derived field regular expression matches a line that has no trace id in the format of the services: {}".format(line))

    tj = tempo.get("jsonData") or {}
    link = tj.get("tracesToLogsV2")
    if not link:
        fail("the Tempo data source has no tracesToLogsV2 (the link from a trace to its logs)")
    else:
        target = by_uid.get(link.get("datasourceUid"))
        if target is None or target.get("type") != "loki":
            fail("the trace to logs link must point at the Loki data source by its uid (it points at {})".format(link.get("datasourceUid")))
        before, after = str(link.get("spanStartTimeShift", "")), str(link.get("spanEndTimeShift", ""))
        if not re.fullmatch(r"-\d+[smh]", before) or not re.fullmatch(r"\d+[smh]", after):
            fail("the trace to logs link needs a time shift before (negative) and after (positive) the span (it has '{}' and '{}')".format(before, after))
        query = _unescape(link.get("query", ""))
        if link.get("customQuery") is not True or "${__trace.traceId}" not in query:
            fail("the trace to logs link must be a custom query that uses ${{__trace.traceId}} (it is '{}')".format(link.get("query")))
        else:
            problems.extend(check_logql(query.replace("${__trace.traceId}", "x"), {}, label + ": the trace to logs query"))
    for key in ("serviceMap", "tracesToMetrics"):
        if tj.get(key):
            fail("{} needs metrics from Tempo's metrics generator, which is off".format(key))
    if (tj.get("nodeGraph") or {}).get("enabled"):
        fail("the node graph needs the metrics generator of Tempo, which is off")
    return problems


ALLOY_NAMESPACES = ["data", "shop"]


def check_alloy(docs, label):
    """The Alloy configuration: logs only through the Kubernetes API, from two namespaces, no log field as a label."""
    data = _config_map(docs, "alloy")
    if data is None or "config.alloy" not in data:
        return ["{}: no ConfigMap alloy with a config.alloy".format(label)]
    text = data["config.alloy"]
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    if "loki.source.kubernetes" not in text:
        fail("the logs must be read with loki.source.kubernetes")
    for banned in ("loki.source.file", "local.file_match", "loki.source.podlogs"):
        if banned in text:
            fail("{} reads files or CRDs from the node and is not allowed here".format(banned))
    for banned in ("stage.labels", "stage.label_keep", "stage.static_labels"):
        if banned in text:
            fail("{} would turn parts of a log line into labels; use stage.structured_metadata".format(banned))
    if "stage.structured_metadata" not in text:
        fail("the level must be stored with stage.structured_metadata")
    found = []
    for m in re.finditer(r"namespaces\s*\{\s*names\s*=\s*\[([^\]]*)\]", text):
        found.extend(re.findall(r'"([^"]+)"', m.group(1)))
    if sorted(found) != ALLOY_NAMESPACES:
        fail("the collected namespaces must be exactly {} (found {})".format(", ".join(ALLOY_NAMESPACES), ", ".join(sorted(found)) or "none"))
    for d in docs:
        if d["kind"] in ("ClusterRole", "Role"):
            for rule in d.get("rules") or []:
                if set(rule.get("resources") or []) & {"secrets", "configmaps"}:
                    fail("{} can read {}; log collection does not need that".format(name_of(d), ", ".join(sorted(rule["resources"]))))
    return problems


# The annotation that client-side apply stores the last applied configuration in is limited to 256 KiB.
ANNOTATION_LIMIT = 262144
REQUIRED_CRDS = ("alertmanagers", "podmonitors", "probes", "prometheuses", "prometheusrules", "servicemonitors")


def check_crds(docs, label, appset_file):
    crds = [d for d in docs if d["kind"] == "CustomResourceDefinition"]
    if not crds:
        return ["{}: no CustomResourceDefinition rendered (crds.enabled, or render with --include-crds)".format(label)]
    problems = []
    names = {d["metadata"]["name"] for d in crds}
    for plural in REQUIRED_CRDS:
        if "{}.monitoring.coreos.com".format(plural) not in names:
            problems.append("{}: the CRD {}.monitoring.coreos.com is not rendered".format(label, plural))
    for d in crds:
        spec = d.get("spec") or {}
        where = name_of(d)
        if d.get("apiVersion") != "apiextensions.k8s.io/v1":
            problems.append("{}: {} is {}, not apiextensions.k8s.io/v1".format(label, where, d.get("apiVersion")))
        plural = (spec.get("names") or {}).get("plural")
        if d["metadata"]["name"] != "{}.{}".format(plural, spec.get("group")):
            problems.append("{}: {} is not named <plural>.<group>".format(label, where))
        versions = spec.get("versions") or []
        if sum(1 for v in versions if v.get("storage")) != 1:
            problems.append("{}: {} must have exactly one storage version".format(label, where))
        for v in versions:
            if v.get("served") and not (v.get("schema") or {}).get("openAPIV3Schema"):
                problems.append("{}: {} serves {} without a schema".format(label, where, v.get("name")))
    large = [d for d in crds if len(json.dumps(d)) > ANNOTATION_LIMIT]
    if large:
        text = open(appset_file, encoding="utf-8").read()
        if "ServerSideApply=true" not in text:
            problems.append(
                "{}: {} CRD(s) exceed {} bytes ({}), which client-side apply cannot store; {} must sync with "
                "ServerSideApply=true".format(
                    label, len(large), ANNOTATION_LIMIT, ", ".join(sorted(d["metadata"]["name"] for d in large)), appset_file
                )
            )
    return problems


PROMQL_WORDS = {
    "by", "without", "on", "ignoring", "group_left", "group_right", "bool", "offset", "and", "or", "unless",
    "sum", "avg", "min", "max", "count", "group", "topk", "bottomk", "quantile", "stddev", "stdvar",
    "count_values", "limitk", "limit_ratio", "inf", "nan",
}  # fmt: skip
SOURCE_SUFFIXES = (".go", ".py", ".java", ".yaml", ".yml", ".json", ".tpl")
SOURCE_SKIP_DIRS = {".venv", "target", "node_modules", ".git", "__pycache__", ".pytest_cache", ".ruff_cache", "bin", "tests", "test"}


def metrics_in(expr):
    """The metric names a PromQL expression selects. Label names, functions, variables and strings are left out."""
    e = re.sub(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'', "", expr)
    e = re.sub(r"\$\{?[A-Za-z_]\w*\}?", "", e)
    e = re.sub(r"\{[^}]*\}", "", e)
    e = re.sub(r"\[[^\]]*\]", "", e)
    e = re.sub(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", "", e)
    names = []
    for m in re.finditer(r"\b([A-Za-z_:][A-Za-z0-9_:]*)\b(\s*\()?", e):
        if m.group(2) or m.group(1) in PROMQL_WORDS:
            continue
        names.append(m.group(1))
    return names


def _is_test_file(name):
    return name.endswith(("_test.go", "Test.java", "Tests.java")) or name.startswith("test_") or name == "conftest.py"


def load_sources(paths):
    """(declared names, text) from source directories, vendored chart tarballs and lists of names."""
    declared, chunks = set(), []
    for path in paths:
        if os.path.isdir(path):
            for root, dirs, files in os.walk(path):
                dirs[:] = [d for d in dirs if d not in SOURCE_SKIP_DIRS]
                for f in files:
                    if f.endswith(SOURCE_SUFFIXES) and not _is_test_file(f):
                        chunks.append(open(os.path.join(root, f), encoding="utf-8", errors="replace").read())
        elif path.endswith((".tgz", ".tar.gz")):
            with tarfile.open(path) as tar:
                for member in tar.getmembers():
                    if member.isfile():
                        chunks.append(tar.extractfile(member).read().decode("utf-8", errors="replace"))
        elif path.endswith((".yaml", ".yml")):
            # Rendered rules: a recording rule defines the series it records, an alert defines ALERTS and its state.
            for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
                if isinstance(doc, dict) and doc.get("kind") == "PrometheusRule":
                    for group in (doc.get("spec") or {}).get("groups") or []:
                        for rule in group.get("rules") or []:
                            if rule.get("record"):
                                declared.add(rule["record"])
        elif path.endswith(".txt"):
            for line in open(path, encoding="utf-8"):
                line = line.split("#", 1)[0].strip()
                if line:
                    declared.add(line)
        else:
            raise ValueError("unknown source: " + path)
    return declared, "\n".join(chunks)


# The data source variable each type of data source must be referenced through: never a fixed uid or a name.
DATASOURCE_VARIABLES = {"prometheus": "datasource", "loki": "loki"}


def _datasource_refs(node, where, problems, used):
    """Check every data source reference in a dashboard; the types referenced are added to the set `used`."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "datasource":
                kind = value.get("type") if isinstance(value, dict) else None
                if kind in DATASOURCE_VARIABLES and value.get("uid") == "${" + DATASOURCE_VARIABLES[kind] + "}":
                    used.add(kind)
                else:
                    problems.append(
                        "{} has the data source {!r}; it must be the variable {{type: prometheus, uid: ${{datasource}}}} "
                        "or {{type: loki, uid: ${{loki}}}}".format(where, value)
                    )
            else:
                _datasource_refs(value, where, problems, used)
    elif isinstance(node, list):
        for item in node:
            _datasource_refs(item, where, problems, used)


# Labels that exist on the log streams Alloy sends (platform/observability/alloy) plus service_name, which Loki adds. The
# level is structured metadata taken from JSON lines: it can be filtered on and grouped by, but it is not in the index.
LOKI_STREAM_LABELS = {"namespace", "pod", "container", "app", "service", "service_name"}
LOKI_METADATA_LABELS = {"level"}
GRAFANA_INTERVALS = {"__auto", "__interval", "__interval_ms", "__rate_interval", "__range", "__range_s", "__range_ms", "__from", "__to"}
LOGQL_MATCHER = re.compile(r'([A-Za-z_]\w*)\s*(=~|!~|!=|=)\s*("(?:[^"\\]|\\.)*"|`[^`]*`)')


def _empty_compatible(regex):
    try:
        return re.fullmatch(regex, "") is not None
    except re.error:
        return True


def check_logql(expr, variables, where):
    """Problems with a LogQL expression that can be seen without a server: labels, empty selectors, variables, brackets.
    Whether Loki accepts the syntax is checked against the Loki image by scripts/observability-check.sh."""
    problems = []
    plain = re.sub(r'"(?:[^"\\]|\\.)*"|`[^`]*`', '""', expr)
    for open_, close in (("{", "}"), ("(", ")"), ("[", "]")):
        if plain.count(open_) != plain.count(close):
            problems.append("{}: the query has unbalanced {}{}: {}".format(where, open_, close, expr))
    # Backtick strings are raw: quotes and backslashes inside them are text, so they are looked at first.
    unquoted = re.sub(r"`[^`]*`", "", expr)
    if expr.count("`") % 2:
        problems.append("{}: the query has an unclosed backtick: {}".format(where, expr))
    elif unquoted.count('"') % 2:
        problems.append("{}: the query has an unclosed double quote: {}".format(where, expr))
    for ref in re.findall(r'"(?:[^"\\]|\\.)*"', unquoted):
        if re.search(r"\$\{?search\}?", ref):
            problems.append("{}: the search text is inside a double-quoted string, which breaks on a double quote or a backslash; "
                            "use a backtick string".format(where))
    for name in re.findall(r"\$\{?([A-Za-z_]\w*)\}?", expr):
        if name not in variables and name not in GRAFANA_INTERVALS:
            problems.append("{}: the query uses ${}, which is not a variable of the dashboard".format(where, name))
    selectors = re.findall(r"\{([^{}]*)\}", expr)
    if not selectors:
        problems.append("{}: the query has no stream selector: {}".format(where, expr))
    for selector in selectors:
        counted = False
        for label, op, value in LOGQL_MATCHER.findall(selector):
            if label not in LOKI_STREAM_LABELS:
                problems.append("{}: the selector uses the label {}, which is not a log stream label ({})".format(
                    where, label, ", ".join(sorted(LOKI_STREAM_LABELS))))
            text = value[1:-1]
            if op == "=":
                counted = counted or text != ""
            elif op == "=~":
                ref = re.fullmatch(r"\$\{?([A-Za-z_]\w*)\}?", text)
                if ref and ref.group(1) in variables:
                    var = variables[ref.group(1)]
                    # "All" is the worst case: it must still exclude the empty value.
                    if not var.get("includeAll"):
                        counted = True
                    elif not _empty_compatible(str(var.get("allValue", ".*"))):
                        counted = True
                elif not _empty_compatible(text):
                    counted = True
        if not counted:
            problems.append(
                "{}: the selector {{{}}} has no matcher that excludes the empty value, which Loki refuses "
                "(use an allValue of .+ on the variable, or an equality matcher)".format(where, selector))
    for label, _op in re.findall(r"\|\s*([A-Za-z_]\w*)\s*(=~|!~|!=|==|>=|<=|=|>|<)", plain):
        if label not in LOKI_STREAM_LABELS | LOKI_METADATA_LABELS:
            problems.append("{}: the label filter uses {}, which is not a stream label or the level".format(where, label))
    for group in re.findall(r"\b(?:by|without)\s*\(([^)]*)\)", plain):
        for label in [g.strip() for g in group.split(",") if g.strip()]:
            if label not in LOKI_STREAM_LABELS | LOKI_METADATA_LABELS:
                problems.append("{}: the query groups by {}, which is not a stream label or the level".format(where, label))
    return problems


def loki_queries(files_dir, searches=()):
    """(dashboard, panel or variable, expression with Grafana variables filled in, kind) for every Loki query in the
    dashboards, once with "All" selected and once with concrete values, for scripts/observability-check.sh to run.
    searches is a list of (name, text): the queries that use the search variable are also returned once for each text,
    with the other variables on "All"."""
    out = []
    for path in sorted(glob.glob(files_dir + "/*.json")):
        board = json.load(open(path, encoding="utf-8"))
        variables = {v["name"]: v for v in (board.get("templating") or {}).get("list") or []}
        items = []
        for panel in board.get("panels") or []:
            for target in panel.get("targets") or []:
                ds = target.get("datasource") or panel.get("datasource") or {}
                if ds.get("type") == "loki" and target.get("expr"):
                    items.append((panel.get("title"), target["expr"], target.get("queryType", "range")))
        for v in variables.values():
            q = v.get("query")
            q = q.get("query", "") if isinstance(q, dict) else q
            if v.get("type") == "query" and (v.get("datasource") or {}).get("type") == "loki" and q:
                m = re.match(r"^label_values\((.*),\s*[A-Za-z_]\w*\)$", q.strip(), re.S)
                if m:
                    items.append(("variable " + v["name"], m.group(1), "selector"))
        for title, expr, kind in items:
            modes = [("all", {}), ("concrete", {"namespace": "shop", "service": "gateway|payments", "search": "request"})]
            if re.search(r"\$\{?search\}?", expr):
                modes += [("search " + name, {"search": value}) for name, value in searches]
            for mode, values in modes:
                text = expr
                for name, var in variables.items():
                    if var.get("type") == "datasource":
                        continue
                    if name in values:
                        value = values[name]
                    elif name == "search":
                        value = ""
                    else:
                        value = str(var.get("allValue", ".*"))
                    text = text.replace("${" + name + "}", value).replace("$" + name, value)
                text = re.sub(r"\$(?:__auto|__interval|__rate_interval)", "1m", text)
                out.append((os.path.basename(path), "{} ({})".format(title, mode), text, kind))
    return out


def make_confirmer(sources):
    """(confirmed, text): confirmed(name) is true when a metric name (or its histogram base) appears in a source."""
    declared, text = load_sources(sources)

    def confirmed(name):
        for candidate in (name, re.sub(r"_(bucket|sum|count)$", "", name)):
            if candidate in declared or re.search(r"(?<![A-Za-z0-9_:])" + re.escape(candidate) + r"(?![A-Za-z0-9_:])", text):
                return True
        return False

    return confirmed, text


def check_dashboards(docs, label, files_dir, stack_values, sources):
    problems = []
    confirmed, _text = make_confirmer(sources)

    files = sorted(glob.glob(files_dir + "/*.json"))
    if not files:
        return ["{}: no dashboard JSON in {}".format(label, files_dir)]
    parsed, uids, titles = {}, {}, {}
    for path in files:
        base = os.path.basename(path)
        where = "{}: {}".format(label, base)
        try:
            board = json.load(open(path, encoding="utf-8"))
        except ValueError as e:
            problems.append("{} is not valid JSON ({})".format(where, e))
            continue
        parsed[base] = board
        uid, title = board.get("uid"), board.get("title")
        if not uid or not title:
            problems.append("{} needs a uid and a title".format(where))
            continue
        if uid != base[:-5]:
            problems.append("{}: the uid '{}' must equal the file name '{}'".format(where, uid, base[:-5]))
        if len(uid) > 40:
            problems.append("{}: the uid is longer than 40 characters".format(where))
        if uid in uids:
            problems.append("{}: the uid '{}' is also used by {}".format(where, uid, uids[uid]))
        if title in titles:
            problems.append("{}: the title '{}' is also used by {}".format(where, title, titles[title]))
        uids.setdefault(uid, base)
        titles.setdefault(title, base)

        variables = (board.get("templating") or {}).get("list") or []
        by_name = {v.get("name"): v for v in variables}
        used = set()
        _datasource_refs(board, where, problems, used)
        for kind in sorted(used):
            name = DATASOURCE_VARIABLES[kind]
            if not any(v.get("name") == name and v.get("type") == "datasource" and v.get("query") == kind for v in variables):
                problems.append("{} has no data source variable (name {}, type datasource, query {})".format(where, name, kind))

        exprs, ids = [], set()
        for panel in board.get("panels") or []:
            if panel.get("id") in ids:
                problems.append("{}: panel id {} is used twice".format(where, panel.get("id")))
            ids.add(panel.get("id"))
            pos = panel.get("gridPos") or {}
            if pos.get("x", 0) + pos.get("w", 0) > 24:
                problems.append("{}: panel '{}' is wider than the 24-column grid".format(where, panel.get("title")))
            if panel.get("type") == "row":
                continue
            if not panel.get("title"):
                problems.append("{}: panel {} has no title".format(where, panel.get("id")))
            if not panel.get("targets"):
                problems.append("{}: panel '{}' has no query".format(where, panel.get("title")))
            for target in panel.get("targets") or []:
                if not (target.get("expr") or "").strip():
                    problems.append("{}: panel '{}' has an empty query".format(where, panel.get("title")))
                ds = target.get("datasource") or panel.get("datasource") or {}
                kind = ds.get("type") if isinstance(ds, dict) else None
                if kind == "loki":
                    problems.extend(check_logql(target.get("expr") or "", by_name, "{}: panel '{}'".format(where, panel.get("title"))))
                else:
                    exprs.append(target.get("expr") or "")
        for v in variables:
            if v.get("type") == "query":
                q = (v.get("query") or {}).get("query", "") if isinstance(v.get("query"), dict) else v.get("query", "")
                m = re.match(r"^label_values\((.*),\s*[A-Za-z_]\w*\)$", q.strip(), re.S)
                if not m:
                    problems.append("{}: the variable '{}' must be label_values(<selector>, <label>), not '{}'".format(where, v.get("name"), q))
                elif (v.get("datasource") or {}).get("type") == "loki":
                    problems.extend(check_logql(m.group(1), by_name, "{}: variable '{}'".format(where, v.get("name"))))
                    wanted = re.search(r",\s*([A-Za-z_]\w*)\)\s*$", q.strip()).group(1)
                    if wanted not in LOKI_STREAM_LABELS:
                        problems.append("{}: the variable '{}' lists values of {}, which is not a log stream label".format(where, v.get("name"), wanted))
                else:
                    exprs.append(m.group(1))
        unknown = sorted({n for expr in exprs for n in metrics_in(expr) if not confirmed(n)})
        for name in unknown:
            problems.append("{} uses the metric {}, which is not confirmed in any source (service code, vendored chart, confirmed-upstream list)".format(where, name))

    # The rendered ConfigMaps.
    stack = yaml.safe_load(open(stack_values, encoding="utf-8"))
    side = stack["kube-prometheus-stack"]["grafana"]["sidecar"]["dashboards"]
    want = (side["label"], str(side["labelValue"]))
    maps = [d for d in docs if d["kind"] == "ConfigMap"]
    seen = set()
    for d in maps:
        labels = (d.get("metadata") or {}).get("labels") or {}
        if (want[0], str(labels.get(want[0]))) != want:
            problems.append("{}: {} does not carry the sidecar label {}: \"{}\"".format(label, name_of(d), want[0], want[1]))
        for key, body in (d.get("data") or {}).items():
            seen.add(key)
            if key not in parsed:
                problems.append("{}: {} holds {}, which is not a file in {}".format(label, name_of(d), key, files_dir))
            elif json.loads(body) != parsed[key]:
                problems.append("{}: {} holds {} with different content than the file".format(label, name_of(d), key))
    for base in sorted(set(parsed) - seen):
        problems.append("{}: {} is not in any rendered ConfigMap".format(label, base))
    others = [d for d in docs if d["kind"] != "ConfigMap"]
    for d in others:
        problems.append("{}: {} is rendered; the dashboards chart holds ConfigMaps only".format(label, name_of(d)))
    return problems


SLO_WINDOWS = ("5m", "30m", "1h", "2h", "6h", "1d", "3d", "30d")
SLO_EVENT_WINDOWS = ("1h", "6h", "1d", "3d")
# alert name, severity, burn rate, long window, short window (Google SRE Workbook, multi-window multi-burn-rate)
SLO_ALERTS = (
    ("PageFast", "page", "14.4", "1h", "5m"),
    ("PageSlow", "page", "6", "6h", "30m"),
    ("TicketFast", "ticket", "3", "1d", "2h"),
    ("TicketSlow", "ticket", "1", "3d", "6h"),
)
SLO_OPERATIONAL_ROUTES = ("/healthz", "/readyz", "/metrics")
SLO_MIN_GUARD = 3  # fewer bad events than this at the alert threshold would let one or two failures alert
SLO_RUNBOOK = re.compile(r"^https://\S+/docs/runbooks/alerts\.md#[a-z0-9]+(?:-[a-z0-9]+)*$")
SLO_RECORD = re.compile(r"^slo:(?:objective:ratio|error_budget:ratio|sli_error:ratio_rate(\d+[mhd])|sli_events:increase(\d+[mhd]))$")


def _selectors(expr, metric):
    """The {...} selector bodies that follow a metric name in a PromQL expression."""
    return re.findall(r"(?<![A-Za-z0-9_:])" + re.escape(metric) + r"\{([^}]*)\}", expr)


def check_slo_rules(docs, label, sources):
    problems = []

    def fail(message):
        problems.append("{}: {}".format(label, message))

    rules_docs = [d for d in docs if d.get("kind") == "PrometheusRule" and (d.get("metadata") or {}).get("name") == "slo"]
    if len(rules_docs) != 1:
        return ["{}: expected exactly one PrometheusRule named slo, found {}".format(label, len(rules_docs))]
    groups = (rules_docs[0].get("spec") or {}).get("groups") or []
    rules = [r for g in groups for r in g.get("rules") or []]
    recording = {}  # (name, slo) -> rule
    alerts = {}  # (name, slo) -> rule
    for r in rules:
        labels = r.get("labels") or {}
        if "record" in r:
            m = SLO_RECORD.match(r["record"])
            if not m:
                fail("the recording rule {} does not follow slo:<what>:<unit>[_<window>] (objective:ratio, error_budget:ratio, sli_error:ratio_rate<window>, sli_events:increase<window>)".format(r["record"]))
                continue
            if not labels.get("slo") or not labels.get("service"):
                fail("the recording rule {} needs the labels slo and service".format(r["record"]))
                continue
            recording[(r["record"], labels["slo"])] = r
            window = m.group(1) or m.group(2)
            if window and ("[{}]".format(window) not in r.get("expr", "")):
                fail("{} for {} does not use a [{}] range".format(r["record"], labels["slo"], window))
        elif "alert" in r:
            alerts[(r["alert"], labels.get("slo", ""))] = r

    slos = sorted({slo for (name, slo) in recording if name == "slo:objective:ratio"})
    if not slos:
        return ["{}: no SLO found (no slo:objective:ratio rule)".format(label)]

    confirmed, text = make_confirmer(sources)
    buckets = set()
    for m in re.finditer(r"Buckets\s*=\s*\[\]float64\{([^}]*)\}", text):
        buckets.update(float(x) for x in re.findall(r"[0-9.]+", m.group(1)))

    def vector_value(rule):
        m = re.fullmatch(r"vector\(([0-9.]+)\)", (rule.get("expr") or "").strip())
        return float(m.group(1)) if m else None

    for slo in slos:
        objective = vector_value(recording[("slo:objective:ratio", slo)])
        budget_rule = recording.get(("slo:error_budget:ratio", slo))
        budget = vector_value(budget_rule) if budget_rule else None
        if objective is None or budget is None:
            fail("{}: slo:objective:ratio and slo:error_budget:ratio must be vector(<number>)".format(slo))
        elif abs(objective + budget - 1) > 1e-9:
            fail("{}: the objective {} and the error budget {} do not add up to 1".format(slo, objective, budget))
        for w in SLO_WINDOWS:
            if ("slo:sli_error:ratio_rate" + w, slo) not in recording:
                fail("{} has no recording rule slo:sli_error:ratio_rate{}".format(slo, w))
        for w in SLO_EVENT_WINDOWS:
            if ("slo:sli_events:increase" + w, slo) not in recording:
                fail("{} has no recording rule slo:sli_events:increase{}".format(slo, w))
        for name, severity, burn, long_w, short_w in SLO_ALERTS:
            alert = alerts.get(("SLOBurnRate" + name, slo))
            where = "{} alert SLOBurnRate{}".format(slo, name)
            if alert is None:
                fail("{} has no alert SLOBurnRate{}".format(slo, name))
                continue
            expr = " ".join((alert.get("expr") or "").split())
            labels = alert.get("labels") or {}
            if labels.get("severity") != severity:
                fail("{} must have severity {} (it has {})".format(where, severity, labels.get("severity")))
            if labels.get("slo") != slo or not labels.get("service"):
                fail("{} needs the labels slo ({}) and service".format(where, slo))
            threshold = r"\(" + re.escape(burn) + r" \* slo:error_budget:ratio\{slo=\"" + re.escape(slo) + r"\"\}\)"
            for window in (long_w, short_w):
                pattern = r"slo:sli_error:ratio_rate" + window + r"\{slo=\"" + re.escape(slo) + r"\"\} > " + threshold
                if not re.search(pattern, expr):
                    fail("{} must compare slo:sli_error:ratio_rate{} to {} x the error budget".format(where, window, burn))
            guard = re.search(r"slo:sli_events:increase" + long_w + r"\{slo=\"" + re.escape(slo) + r"\"\} \* " + threshold + r" >= ([0-9.]+)", expr)
            if not guard:
                fail("{} needs the low-traffic guard: slo:sli_events:increase{} x ({} x the error budget) >= a minimum".format(where, long_w, burn))
            elif float(guard.group(1)) < SLO_MIN_GUARD:
                fail("{} has a low-traffic guard of {}, below the minimum of {} bad events".format(where, guard.group(1), SLO_MIN_GUARD))
            if " and " not in expr or expr.count(" and ") != 2:
                fail("{} must join the long window, the short window and the guard with 'and'".format(where))
            if not alert.get("for"):
                fail("{} needs a 'for' duration".format(where))

    for (name, slo), alert in sorted(alerts.items()):
        where = "alert {}".format(name)
        ann = alert.get("annotations") or {}
        for key in ("summary", "description", "runbook_url"):
            if not (ann.get(key) or "").strip():
                fail("{} ({}) needs the annotation {}".format(where, slo or "no slo", key))
        if ann.get("runbook_url") and not SLO_RUNBOOK.match(ann["runbook_url"]):
            fail("{} runbook_url must end in docs/runbooks/alerts.md#<anchor> (lower case, hyphens), it is {}".format(where, ann["runbook_url"]))
        if (alert.get("labels") or {}).get("severity") not in ("page", "ticket"):
            fail("{} needs severity page or ticket".format(where))
        if not (alert.get("labels") or {}).get("service"):
            fail("{} ({}) needs the label service, which the Alertmanager inhibitions and the grouping use".format(where, slo or "no slo"))
        if not name.startswith("SLOBurnRate") and slo:
            fail("{} has an slo label but is not a burn-rate alert".format(where))
    anchors = {}
    for (name, _slo), alert in alerts.items():
        url = (alert.get("annotations") or {}).get("runbook_url") or ""
        anchors.setdefault(name, set()).add(url)
    for name, urls in sorted(anchors.items()):
        if len(urls) > 1:
            fail("alert {} has more than one runbook_url".format(name))
    if len({next(iter(u)) for u in anchors.values() if len(u) == 1}) != len([u for u in anchors.values() if len(u) == 1]):
        fail("two different alerts share a runbook anchor")

    # What the expressions select.
    for r in rules:
        expr = r.get("expr") or ""
        where = r.get("record") or r.get("alert")
        for metric in sorted({n for n in metrics_in(expr) if not n.startswith("slo:") and n not in ("up", "vector")}):
            if not confirmed(metric):
                fail("{} uses the metric {}, which is not confirmed in any source (service code)".format(where, metric))
        for le in re.findall(r'le="([^"]+)"', expr):
            if le != "+Inf" and buckets and float(le) not in buckets:
                fail("{} uses le=\"{}\", which is not a bucket boundary of the services' histogram ({})".format(where, le, ", ".join("{:g}".format(b) for b in sorted(buckets))))
            if not buckets:
                fail("{} uses le=\"{}\", but no histogram buckets were found in the sources".format(where, le))
        if where and where.startswith("slo:sli_"):
            for metric in ("http_requests_total", "http_request_duration_seconds_count", "http_request_duration_seconds_bucket"):
                for body in _selectors(expr, metric):
                    if 'service="gateway"' in body and not all(route in body for route in SLO_OPERATIONAL_ROUTES):
                        fail("{} selects {} without leaving out the routes {}".format(where, metric, ", ".join(SLO_OPERATIONAL_ROUTES)))
    for slo in slos:
        if slo.endswith("availability"):
            rule = recording.get(("slo:sli_error:ratio_rate5m", slo))
            totals = _selectors(re.split(r"\n/\n", (rule or {}).get("expr", ""))[-1], "http_requests_total")
            if rule and not any('status!~"4.."' in body for body in totals):
                fail("{}: the valid events must leave out client errors (status!~\"4..\")".format(slo))
    return problems


def _wildcard(rule, group, kind):
    return rule.get("group") in (group, "*") and rule.get("kind") in (kind, "*")


def check_project_fit(docs, label, project_file, default_namespace):
    project = yaml.safe_load(open(project_file, encoding="utf-8"))
    spec = project["spec"]
    namespaces = {dst.get("namespace") for dst in spec.get("destinations") or []}
    cluster_rules = spec.get("clusterResourceWhitelist") or []
    namespaced_rules = spec.get("namespaceResourceWhitelist") or []
    problems = []
    for d in docs:
        api = str(d.get("apiVersion", ""))
        group = api.split("/")[0] if "/" in api else ""
        kind = d["kind"]
        ns = (d.get("metadata") or {}).get("namespace")
        if kind in CLUSTER_SCOPED:
            if not any(_wildcard(r, group, kind) for r in cluster_rules):
                problems.append("{}: {} ({}) is cluster-scoped and not in clusterResourceWhitelist of {}".format(
                    label, name_of(d), group or "core", project["metadata"]["name"]))
            continue
        ns = ns or default_namespace
        if ns not in namespaces and "*" not in namespaces:
            problems.append("{}: {} is in the namespace {}, which is not a destination of {}".format(
                label, name_of(d), ns, project["metadata"]["name"]))
        if not any(_wildcard(r, group, kind) for r in namespaced_rules):
            problems.append("{}: {} ({}) is not in namespaceResourceWhitelist of {}".format(
                label, name_of(d), group or "core", project["metadata"]["name"]))
    return problems


def table_waves(readme):
    """{ApplicationSet name: wave} from the README table of '| wave | `name`, `name` ... |' rows."""
    waves = {}
    for line in open(readme, encoding="utf-8"):
        m = re.match(r"^\|\s*(-?\d+)\s*\|(.*)\|\s*$", line)
        if not m:
            continue
        for token in re.findall(r"`([a-z0-9-]+)`", m.group(2)):
            waves[token] = int(m.group(1))
    return waves


def check_waves(apps_dir, readme):
    problems = []
    actual = {}
    for path in sorted(glob.glob(apps_dir + "/*.yaml")):
        for d in yaml.safe_load_all(open(path, encoding="utf-8")):
            if isinstance(d, dict) and d.get("kind") == "ApplicationSet":
                wave = annotations(d).get(WAVE)
                actual[d["metadata"]["name"]] = (int(wave) if wave is not None else None, path)
    documented = table_waves(readme)

    def wave(name):
        w = actual.get(name, (None, ""))[0]
        if w is None:
            problems.append("ApplicationSet {} has no {} annotation (or does not exist)".format(name, WAVE))
        return w

    # Intent: the order the ApplicationSets are created in.
    before = [
        ("data-namespaces", "data-secrets"),
        ("data-storage", "data-postgres"),
        ("data-secrets", "data-postgres"),
        ("data-secrets", "data-valkey"),
        ("data-secrets", "data-rabbitmq"),
        ("data-cnpg-operator", "data-postgres"),
        ("data-rabbitmq-operator", "data-rabbitmq"),
        ("data-rabbitmq", "data-rabbitmq-credentials"),
        ("data-rabbitmq-credentials", "apps-orders"),
        ("data-postgres", "apps-orders"),
        ("data-postgres", "apps-payments"),
        ("observability-secrets", "observability-stack"),
        ("observability-stack", "observability-collector"),
        ("observability-stack", "observability-monitors"),
        ("observability-stack", "observability-dashboards"),
        ("observability-stack", "observability-loki"),
        ("observability-loki", "observability-alloy"),
        ("observability-tempo", "observability-collector"),
    ]
    for first, second in before:
        a, b = wave(first), wave(second)
        if a is not None and b is not None and not a < b:
            problems.append("sync-wave order: {} (wave {}) must come before {} (wave {})".format(first, a, second, b))

    # The README must say what the files say.
    for name, (w, path) in sorted(actual.items()):
        if not name.startswith(("data-", "apps-", "observability-")):
            continue
        if name not in documented:
            problems.append("{} ({}) is not in the wave table of {}".format(name, path, readme))
        elif w is not None and documented[name] != w:
            problems.append(
                "{}: wave {} in {} but {} in the table of {}".format(name, w, path, documented[name], readme)
            )
    for name in documented:
        if name.startswith(("data-", "apps-", "observability-")) and name not in actual:
            problems.append("{} is in the wave table of {} but no ApplicationSet has that name".format(name, readme))
    return problems


def main(argv):
    per_chart = {
        "hooks": check_hooks,
        "secret-jobs": check_secret_jobs,
        "postgres-gate": check_postgres_gate,
        "restricted": check_restricted,
        "ephemeral": check_ephemeral,
        "grafana-admin": check_grafana_admin,
        "digest-pinned": check_digest_pinned,
        "loki": check_loki,
        "tempo": check_tempo,
        "alertmanager": check_alertmanager,
        "grafana-datasources": check_grafana_datasources,
        "alloy": check_alloy,
    }
    if len(argv) == 3 and argv[1] in per_chart:
        problems = per_chart[argv[1]](load_stdin(), argv[2])
    elif len(argv) >= 6 and argv[1] == "dashboards":
        problems = check_dashboards(load_stdin(), argv[2], argv[3], argv[4], argv[5:])
    elif len(argv) >= 4 and argv[1] == "slo-rules":
        problems = check_slo_rules(load_stdin(), argv[2], argv[3:])
    elif len(argv) == 4 and argv[1] == "crds":
        problems = check_crds(load_stdin(), argv[2], argv[3])
    elif len(argv) == 5 and argv[1] == "project-fit":
        problems = check_project_fit(load_stdin(), argv[2], argv[3], argv[4])
    elif len(argv) == 4 and argv[1] == "waves":
        problems = check_waves(argv[2], argv[3])
    elif len(argv) == 3 and argv[1] == "loki-queries":
        for dashboard, title, expr, kind in loki_queries(argv[2]):
            print("\t".join((dashboard, title, kind, expr)))
        return 0
    else:
        print(__doc__, file=sys.stderr)
        return 2
    for p in problems:
        print("    FAIL " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
