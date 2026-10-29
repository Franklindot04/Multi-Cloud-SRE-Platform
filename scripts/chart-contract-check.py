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
                      the sync-wave ordering of the data ApplicationSets is the documented one: secrets
                      before postgres, valkey and rabbitmq; the credential copy after rabbitmq; operators
                      before what they run; every wave agrees with the table in the README.

The first three read a multi-document YAML stream (the output of `helm template`) on stdin.

Usage: helm template ... | chart-contract-check.py hooks|secret-jobs|postgres-gate LABEL
       chart-contract-check.py waves platform/argocd/apps platform/argocd/README.md
"""

import glob
import re
import sys

import yaml

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
    ]
    for first, second in before:
        a, b = wave(first), wave(second)
        if a is not None and b is not None and not a < b:
            problems.append("sync-wave order: {} (wave {}) must come before {} (wave {})".format(first, a, second, b))

    # The README must say what the files say.
    for name, (w, path) in sorted(actual.items()):
        if not name.startswith(("data-", "apps-")):
            continue
        if name not in documented:
            problems.append("{} ({}) is not in the wave table of {}".format(name, path, readme))
        elif w is not None and documented[name] != w:
            problems.append(
                "{}: wave {} in {} but {} in the table of {}".format(name, w, path, documented[name], readme)
            )
    for name in documented:
        if name.startswith(("data-", "apps-")) and name not in actual:
            problems.append("{} is in the wave table of {} but no ApplicationSet has that name".format(name, readme))
    return problems


def main(argv):
    if len(argv) >= 3 and argv[1] in ("hooks", "secret-jobs", "postgres-gate"):
        docs = load_stdin()
        label = argv[2]
        problems = {"hooks": check_hooks, "secret-jobs": check_secret_jobs, "postgres-gate": check_postgres_gate}[argv[1]](
            docs, label
        )
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
