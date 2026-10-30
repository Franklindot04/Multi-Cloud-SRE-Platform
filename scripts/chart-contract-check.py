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
                      claim template or Prometheus storage, no Alertmanager, no Ingress, no LoadBalancer or
                      NodePort Service
  grafana-admin LABEL Grafana reads its admin account from the Secret grafana-admin and no password is set in the
                      rendered output
  digest-pinned LABEL every container image is pinned by digest
  dashboards LABEL DIR STACK_VALUES SOURCE...
                      every Grafana dashboard in DIR is valid JSON with a unique uid (the file name) and title, uses
                      the data source variable and no fixed data source uid, and uses only metric names that are
                      confirmed in a SOURCE (a source directory, a vendored chart tarball, or a list of names); the
                      rendered ConfigMaps (stdin) carry the label that the Grafana sidecar in STACK_VALUES selects
  crds LABEL APPSET   the Prometheus Operator CRDs are rendered and well formed (kubeconform has no schema for the
                      CustomResourceDefinition kind, so this is the check on them): the CRDs the platform relies on
                      exist, each has one storage version and a schema, and, because the large ones exceed what
                      client-side apply can store in an annotation, the ApplicationSet that deploys the chart
                      syncs with ServerSideApply=true
  project-fit LABEL PROJECT DEFAULT_NAMESPACE
                      every rendered resource is allowed by the AppProject file: its kind, and its namespace
                      (DEFAULT_NAMESPACE where the manifest names none)

The per-chart checks read a multi-document YAML stream (the output of `helm template`) on stdin.

Usage: helm template ... | chart-contract-check.py hooks|secret-jobs|postgres-gate|restricted|ephemeral|grafana-admin|digest-pinned LABEL
       helm template ... | chart-contract-check.py project-fit LABEL PROJECT_FILE DEFAULT_NAMESPACE
       helm template ... --include-crds | chart-contract-check.py crds LABEL APPLICATIONSET_FILE
       helm template ... | chart-contract-check.py dashboards LABEL DASHBOARD_DIR STACK_VALUES SOURCE...
       chart-contract-check.py waves platform/argocd/apps platform/argocd/README.md
"""

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
        if d["kind"] in ("PersistentVolumeClaim", "Alertmanager", "Ingress"):
            problems.append("{}: {} is rendered, which the default profile must not".format(label, where))
        if d["kind"] == "Service" and (d.get("spec") or {}).get("type") in ("LoadBalancer", "NodePort"):
            problems.append("{}: {} is a {} Service; access is by port-forward only".format(label, where, d["spec"]["type"]))
        if d["kind"] == "StatefulSet" and (d.get("spec") or {}).get("volumeClaimTemplates"):
            problems.append("{}: {} has volume claim templates".format(label, where))
        if d["kind"] == "Prometheus" and (d.get("spec") or {}).get("storage"):
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
        elif path.endswith(".txt"):
            for line in open(path, encoding="utf-8"):
                line = line.split("#", 1)[0].strip()
                if line:
                    declared.add(line)
        else:
            raise ValueError("unknown source: " + path)
    return declared, "\n".join(chunks)


def _datasource_refs(node, where, problems):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "datasource":
                if not (isinstance(value, dict) and value.get("uid") == "${datasource}" and value.get("type") == "prometheus"):
                    problems.append("{} has the data source {!r}; it must be the variable {{type: prometheus, uid: ${{datasource}}}}".format(where, value))
            else:
                _datasource_refs(value, where, problems)
    elif isinstance(node, list):
        for item in node:
            _datasource_refs(item, where, problems)


def check_dashboards(docs, label, files_dir, stack_values, sources):
    problems = []
    declared, text = load_sources(sources)

    def confirmed(name):
        for candidate in (name, re.sub(r"_(bucket|sum|count)$", "", name)):
            if candidate in declared or re.search(r"(?<![A-Za-z0-9_:])" + re.escape(candidate) + r"(?![A-Za-z0-9_:])", text):
                return True
        return False

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
        if not any(v.get("name") == "datasource" and v.get("type") == "datasource" and v.get("query") == "prometheus" for v in variables):
            problems.append("{} has no data source variable (name datasource, type datasource, query prometheus)".format(where))
        _datasource_refs(board, where, problems)

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
                exprs.append(target.get("expr") or "")
        for v in variables:
            if v.get("type") == "query":
                q = (v.get("query") or {}).get("query", "") if isinstance(v.get("query"), dict) else v.get("query", "")
                m = re.match(r"^label_values\((.*),\s*[A-Za-z_]\w*\)$", q.strip(), re.S)
                if not m:
                    problems.append("{}: the variable '{}' must be label_values(<selector>, <label>), not '{}'".format(where, v.get("name"), q))
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
    }
    if len(argv) == 3 and argv[1] in per_chart:
        problems = per_chart[argv[1]](load_stdin(), argv[2])
    elif len(argv) >= 6 and argv[1] == "dashboards":
        problems = check_dashboards(load_stdin(), argv[2], argv[3], argv[4], argv[5:])
    elif len(argv) == 4 and argv[1] == "crds":
        problems = check_crds(load_stdin(), argv[2], argv[3])
    elif len(argv) == 5 and argv[1] == "project-fit":
        problems = check_project_fit(load_stdin(), argv[2], argv[3], argv[4])
    elif len(argv) == 4 and argv[1] == "waves":
        problems = check_waves(argv[2], argv[3])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    for p in problems:
        print("    FAIL " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
