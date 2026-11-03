#!/usr/bin/env python3
"""Runs one chaos experiment (chaos/README.md, docs/adr/0029-chaos-experiments.md).

  chaos-run.py EXPERIMENT.yaml                    dry run: validate, print the plan, touch nothing (the default)
  chaos-run.py EXPERIMENT.yaml --execute          run it for real, after you type the name of the cluster
  chaos-run.py --validate EXPERIMENT.yaml...      check the files against chaos/schema/experiment.schema.json (what CI does)
  chaos-run.py --cleanup [--execute]              list (or, with --execute, revert) what an earlier run left behind

Options: --results-dir DIR (default chaos/results, ignored by Git), --namespace NS (cleanup, repeatable), --cluster-pattern RE (cleanup).
Environment: CHAOS_TICK_SECONDS (the pause between two looks at the probes, default 5), CHAOS_PROM_NAMESPACE, CHAOS_PROM_SERVICE and
CHAOS_PROM_PORT (where Prometheus is, default observability, kube-prometheus-stack-prometheus, 9090).

Exit status: 0 the run finished and the hypothesis held (or a dry run, a validation or a cleanup went well); 1 the run was refused or
failed (nothing was injected, or the rollback failed); 2 the experiment file or the command line is not valid; 4 the run finished and the
hypothesis did NOT hold. 4 is a finding, not a failure of the tool: the result file says what happened. 5 the run finished but proved
nothing, because the injection was undone from outside while it ran (Argo CD self-heal puts a replica count back, for example); 130, 143 and
129 the run was interrupted (the rollback ran).

The rules the script keeps (the tests in scripts/chaos-tests.sh break each one):
  - a real run needs --execute and the cluster name typed in full; there is no --yes
  - the kubectl context must be a cluster whose name matches the experiment's clusterNamePattern; only the name is ever printed
  - every object it changes is checked against the experiment's blast radius first; anything else is refused
  - preconditions, then the steady state, then the injection; any probe failing past the grace period, or a page alert, aborts
  - the rollback always runs: after success, abort, error, SIGINT, SIGTERM and SIGHUP
  - it needs no AWS credentials and never calls AWS, Terraform or Git; it changes no file but its result files
"""

import argparse
import datetime
import json
import os
import re
import secrets
import select
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_FILE = os.path.join(REPO, "chaos", "schema", "experiment.schema.json")
DEFAULT_RESULTS = os.path.join(REPO, "chaos", "results")
DEFAULT_CLEANUP_PATTERN = r"^[a-z0-9-]+-dev$"

MANAGED = "chaos.platform.example/managed-by"
MANAGED_VALUE = "chaos-run"
RUN = "chaos.platform.example/run"
EXPERIMENT = "chaos.platform.example/experiment"
ISOLATED = "chaos.platform.example/isolated"
ORIGINAL_REPLICAS = "chaos.platform.example/original-replicas"
ORIGINAL_LABELS = "chaos.platform.example/original-labels"
ARGOCD_TRACKING = "argocd.argoproj.io/tracking-id"
ARGOCD_SKIP = "argocd.argoproj.io/skip-reconcile"
LOAD_VALUE = "chaos-load"  # the value of MANAGED on what scripts/chaos-load.sh makes: expected during a run, found by --cleanup

ACTIONS = ("delete-pod", "drain-node", "scale-to-zero", "apply-network-deny")
ROLLBACK_FOR = {
    "delete-pod": "wait-for-ready",
    "drain-node": "uncordon",
    "scale-to-zero": "restore-replicas",
    "apply-network-deny": "remove-network-deny",
}


class Refused(Exception):
    """The run must not start, or an action must not be taken: nothing was changed (or the change is named)."""


class Interrupted(Exception):
    """A signal arrived."""


class ProbeError(Exception):
    """A query could not be answered or did not give one number."""


def out(message=""):
    print(message, flush=True)


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def stamp(t=None):
    return (t or now()).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------------------------------------------------------------
# The schema validator: only the keywords chaos/schema/experiment.schema.json uses.
# ---------------------------------------------------------------------------------------------------------------------------------

def _type_ok(value, name):
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    return False


def _resolve(schema, root):
    while isinstance(schema, dict) and "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        schema = node
    return schema


def validate(value, schema, root, path="experiment"):
    """The list of problems of VALUE against SCHEMA, each starting with the path of the broken input."""
    schema = _resolve(schema, root)
    problems = []
    if "oneOf" in schema:
        key = schema.get("x-discriminator")
        branches = schema["oneOf"]
        if not isinstance(value, dict) or key not in value:
            return ["{}: required property '{}' is missing".format(path, key)] if isinstance(value, dict) else ["{}: must be an object".format(path)]
        names = [b["properties"][key]["const"] for b in branches]
        for branch, name in zip(branches, names):
            if value[key] == name:
                return validate(value, branch, root, path)
        return ["{}.{}: {!r} is not one of {}".format(path, key, value[key], ", ".join(names))]
    if "const" in schema and value != schema["const"]:
        problems.append("{}: must be {!r}, not {!r}".format(path, schema["const"], value))
    if "type" in schema and not _type_ok(value, schema["type"]):
        return problems + ["{}: must be of type {}, not {}".format(path, schema["type"], type(value).__name__)]
    if "enum" in schema and value not in schema["enum"]:
        problems.append("{}: {!r} is not one of {}".format(path, value, ", ".join(str(e) for e in schema["enum"])))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            problems.append("{}: is shorter than {} characters".format(path, schema["minLength"]))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            problems.append("{}: is longer than {} characters".format(path, schema["maxLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.append("{}: {!r} does not match {}".format(path, value, schema["pattern"]))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.append("{}: {} is below the minimum {}".format(path, value, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            problems.append("{}: {} is above the maximum {}".format(path, value, schema["maximum"]))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            problems.append("{}: needs at least {} item(s)".format(path, schema["minItems"]))
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            problems.append("{}: has more than {} items".format(path, schema["maxItems"]))
        for i, item in enumerate(value):
            if "items" in schema:
                problems += validate(item, schema["items"], root, "{}[{}]".format(path, i))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append("{}: required property '{}' is missing".format(path, key))
        props = schema.get("properties", {})
        for key, item in value.items():
            if key in props:
                problems += validate(item, props[key], root, "{}.{}".format(path, key))
            elif schema.get("additionalProperties") is False:
                problems.append("{}: unknown property '{}'".format(path, key))
    return problems


def load_experiment(path):
    """(experiment, problems): the parsed file and everything wrong with it, from the schema and from the rules across fields."""
    try:
        with open(path, encoding="utf-8") as handle:
            exp = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as err:
        return None, ["{}: cannot be read as YAML: {}".format(path, str(err).splitlines()[0] if str(err) else err)]
    with open(SCHEMA_FILE, encoding="utf-8") as handle:
        schema = json.load(handle)
    problems = validate(exp, schema, schema)
    if not problems:
        problems = semantic_problems(exp, path)
    return exp, problems


def parse_selector(text):
    return dict(pair.split("=", 1) for pair in text.split(","))


def covers(selector_text, labels):
    """True if every key=value of the selector is among LABELS."""
    return all(labels.get(k) == v for k, v in parse_selector(selector_text).items())


def semantic_problems(exp, path):
    """The rules that cross fields: the rollback undoes the injection, the injection stays inside the blast radius, the numbers add up."""
    problems = []
    inj, blast, pre = exp["injection"], exp["blastRadius"], exp["preconditions"]
    action = inj["action"]
    if exp["name"] != os.path.basename(path).rsplit(".", 1)[0]:
        problems.append("experiment.name: {!r} must be the name of the file ({})".format(exp["name"], os.path.basename(path)))
    if exp["rollback"]["action"] != ROLLBACK_FOR[action]:
        problems.append("experiment.rollback.action: {!r} does not undo {} (it needs {})".format(exp["rollback"]["action"], action, ROLLBACK_FOR[action]))
    target = inj["target"]
    if target["namespace"] not in blast["namespaces"]:
        problems.append("experiment.injection.target.namespace: {!r} is not in blastRadius.namespaces".format(target["namespace"]))
    if "selector" in target:
        wanted = parse_selector(target["selector"])
        if not any(parse_selector(s).items() <= wanted.items() for s in blast["selectors"]):
            problems.append("experiment.injection.target.selector: {!r} is not within any selector of blastRadius.selectors".format(target["selector"]))
    else:
        if {"kind": target["kind"], "name": target["name"]} not in blast["workloads"]:
            problems.append("experiment.injection.target: {}/{} is not in blastRadius.workloads".format(target["kind"], target["name"]))
    if action in ("delete-pod", "apply-network-deny") and inj["count"] > blast["maxPods"]:
        problems.append("experiment.injection.count: {} is above blastRadius.maxPods ({})".format(inj["count"], blast["maxPods"]))
    if inj.get("readySelector"):
        wanted = parse_selector(inj["readySelector"])
        if not any(parse_selector(s).items() <= wanted.items() for s in blast["selectors"]):
            problems.append("experiment.injection.readySelector: {!r} is not within any selector of blastRadius.selectors".format(inj["readySelector"]))
    for ns in blast.get("anyPodInNamespaces", []):
        if ns not in blast["namespaces"]:
            problems.append("experiment.blastRadius.anyPodInNamespaces: {!r} is not in blastRadius.namespaces".format(ns))
    if action == "drain-node":
        if inj["count"] > blast["maxNodes"]:
            problems.append("experiment.injection.count: {} is above blastRadius.maxNodes ({})".format(inj["count"], blast["maxNodes"]))
        if pre["minReadyNodes"] < inj["count"] + 1:
            problems.append("experiment.preconditions.minReadyNodes: {} is too low to drain {} node(s); it needs at least {}".format(
                pre["minReadyNodes"], inj["count"], inj["count"] + 1))
    names = [p["name"] for p in exp["steadyState"]]
    if len(set(names)) != len(names):
        problems.append("experiment.steadyState: probe names must be unique")
    alerts = [o["alert"] for o in exp["expectedObservations"]]
    if len(set(alerts)) != len(alerts):
        problems.append("experiment.expectedObservations: alert names must be unique")
    both = sorted(set(alerts) & set(exp.get("mustNotFire", [])))
    if both:
        problems.append("experiment.mustNotFire: {} is also in expectedObservations".format(", ".join(both)))
    try:
        re.compile(pre["clusterNamePattern"])
    except re.error as err:
        problems.append("experiment.preconditions.clusterNamePattern: not a regular expression ({})".format(err))
    return problems


# ---------------------------------------------------------------------------------------------------------------------------------
# The blast radius and kubectl.
# ---------------------------------------------------------------------------------------------------------------------------------

def cluster_name(context):
    """The name of the cluster from a kubectl context. An EKS context is often an ARN with the account in it: only the part after the
    last slash is kept, and nothing else is ever printed."""
    return context.rsplit("/", 1)[-1].strip()


class Blast:
    """What an experiment may touch. Every change goes through permits()."""

    def __init__(self, namespaces, selectors, workloads, max_pods=0, max_nodes=0, cleanup=False, any_pod_namespaces=()):
        self.namespaces = set(namespaces)
        self.any_pod_namespaces = set(any_pod_namespaces)
        self.selectors = list(selectors)
        self.workloads = {(w["kind"], w["name"]) for w in workloads}
        self.max_pods, self.max_nodes = max_pods, max_nodes
        self.cleanup = cleanup
        self.nodes = set()

    @classmethod
    def of(cls, exp):
        b = exp["blastRadius"]
        return cls(b["namespaces"], b["selectors"], b["workloads"], b["maxPods"], b["maxNodes"], any_pod_namespaces=b.get("anyPodInNamespaces", []))

    def allow_node(self, name):
        self.nodes.add(name)

    def ours(self, labels):
        value = (labels or {}).get(MANAGED)
        return value == MANAGED_VALUE or (self.cleanup and value == LOAD_VALUE)

    def permits(self, kind, namespace, name, labels):
        """None if allowed, otherwise the reason it is not."""
        labels = labels or {}
        if kind == "node":
            if name in self.nodes or (self.cleanup and self.ours(labels)):
                return None
            return "node {} is not one the experiment may drain".format(name)
        if namespace not in self.namespaces:
            return "{} {}/{} is in the namespace {}, which is not in the blast radius ({})".format(
                kind, namespace, name, namespace, ", ".join(sorted(self.namespaces)))
        if kind == "pod":
            if self.ours(labels) and (self.cleanup or RUN in labels or ISOLATED in labels):
                return None
            if namespace in self.any_pod_namespaces or any(covers(s, labels) for s in self.selectors):
                return None
            return "pod {}/{} (labels {}) matches none of the selectors of the blast radius ({})".format(
                namespace, name, ",".join("{}={}".format(k, v) for k, v in sorted(labels.items())) or "none", "; ".join(self.selectors))
        if kind in ("deployment", "statefulset"):
            if (kind.capitalize() if kind == "deployment" else "StatefulSet", name) in self.workloads or (self.cleanup and self.ours(labels)):
                return None
            return "{} {}/{} is not one of the workloads of the blast radius".format(kind, namespace, name)
        if kind == "networkpolicy":
            if name.startswith("chaos-") and self.ours(labels):
                return None
            return "network policy {}/{} is not one the experiment made (a name starting with chaos- and the label {})".format(namespace, name, MANAGED)
        return "{} is not a kind the experiment may change".format(kind)


class Kube:
    """kubectl, always against the context that was checked. Reads are free; every change names its target and is checked first."""

    def __init__(self, context, blast):
        self.context, self.blast, self.mutations, self.calls = context, blast, [], 0

    def _run(self, args, input_text=None, timeout=180):
        self.calls += 1
        proc = subprocess.run(["kubectl", "--context", self.context] + list(args), input=input_text, capture_output=True, text=True, timeout=timeout)
        return proc

    def read(self, *args):
        proc = self._run(args)
        if proc.returncode != 0:
            raise Refused("kubectl {} failed: {}".format(" ".join(args[:3]), ((proc.stderr or proc.stdout).strip().splitlines() or ["no output"])[-1]))
        return proc.stdout

    def read_json(self, *args):
        return json.loads(self.read(*(list(args) + ["-o", "json"])))

    def mutate(self, args, kind, namespace, name, labels, what, input_text=None, timeout=180):
        reason = self.blast.permits(kind, namespace, name, labels)
        if reason:
            raise Refused("refused to {}: {}".format(what, reason))
        self.mutations.append({"at": stamp(), "what": what, "kind": kind, "namespace": namespace, "name": name})
        proc = self._run(args, input_text=input_text, timeout=timeout)
        if proc.returncode != 0:
            raise RuntimeError("{} failed: {}".format(what, ((proc.stderr or proc.stdout).strip().splitlines() or ["no output"])[-1]))
        return proc.stdout


def pod_ready(pod):
    if (pod.get("metadata") or {}).get("deletionTimestamp"):
        return False
    status = pod.get("status") or {}
    return status.get("phase") == "Running" and any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions") or [])


def ready_pods(kube, namespace, selector):
    items = kube.read_json("get", "pods", "-n", namespace, "-l", selector)["items"]
    return [p for p in items if pod_ready(p)]


# ---------------------------------------------------------------------------------------------------------------------------------
# Prometheus, through kubectl port-forward (docs/adr/0029-chaos-experiments.md, "How the runner reads Prometheus").
# ---------------------------------------------------------------------------------------------------------------------------------

class Prometheus:
    def __init__(self, context):
        self.context = context
        self.proc = None
        self.base = None

    def start(self):
        namespace = os.environ.get("CHAOS_PROM_NAMESPACE", "observability")
        service = os.environ.get("CHAOS_PROM_SERVICE", "kube-prometheus-stack-prometheus")
        port = os.environ.get("CHAOS_PROM_PORT", "9090")
        self.proc = subprocess.Popen(["kubectl", "--context", self.context, "port-forward", "-n", namespace, "svc/" + service, ":" + port],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.5)
            if ready:
                line = self.proc.stdout.readline()
                m = re.search(r"Forwarding from 127\.0\.0\.1:(\d+)", line)
                if m:
                    self.base = "http://127.0.0.1:" + m.group(1)
                    return
                if not line:
                    break
            if self.proc.poll() is not None:
                break
        self.stop()
        raise Refused("could not open a port-forward to {}/{} to read Prometheus".format(namespace, service))

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def vector(self, query):
        """The samples of an instant query: a list of (labels, value)."""
        url = "{}/api/v1/query?{}".format(self.base, urllib.parse.urlencode({"query": query}))
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                body = json.load(response)
        except (urllib.error.URLError, OSError, ValueError) as err:
            raise ProbeError("Prometheus did not answer: {}".format(err))
        if body.get("status") != "success":
            raise ProbeError("Prometheus returned an error: {}".format(body.get("error", "unknown")))
        data = body["data"]
        if data["resultType"] == "scalar":
            return [({}, float(data["result"][1]))]
        if data["resultType"] != "vector":
            raise ProbeError("the query returned a {}, not a vector".format(data["resultType"]))
        return [(r["metric"], float(r["value"][1])) for r in data["result"]]


COMPARE = {
    "<": lambda a, b: a < b, "<=": lambda a, b: a <= b, ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b, "==": lambda a, b: a == b, "!=": lambda a, b: a != b,
}


def evaluate_probe(prom, probe):
    """{name, value, ok, state}: ok is false for a value that breaks the comparison, for no data when noData is fail, and for an error."""
    result = {"name": probe["name"], "at": stamp(), "value": None, "ok": False, "state": "error"}
    try:
        samples = prom.vector(probe["query"])
    except ProbeError as err:
        result["detail"] = str(err)
        return result
    if not samples:
        result["state"] = "no-data"
        result["ok"] = probe.get("noData", "fail") == "pass"
        return result
    if len(samples) > 1:
        result["detail"] = "the query returned {} samples; a probe must return one".format(len(samples))
        return result
    value = samples[0][1]
    result["value"] = value
    if value != value:
        result["state"] = "nan"
        return result
    result["ok"] = COMPARE[probe["comparator"]](value, probe["threshold"])
    result["state"] = "ok" if result["ok"] else "violated"
    return result


def page_alerts(prom):
    try:
        return sorted({m.get("alertname", "?") for m, _ in prom.vector('ALERTS{alertstate="firing", severity="page"}')})
    except ProbeError as err:
        raise Refused("cannot read the page alerts, so the run is not safe to start or to go on: {}".format(err))


# ---------------------------------------------------------------------------------------------------------------------------------
# The actions. Each registers its rollback BEFORE it changes anything, so that a failure half way is still undone.
# ---------------------------------------------------------------------------------------------------------------------------------

class Run:
    def __init__(self, exp, kube, prom, run_id, tick):
        self.exp, self.kube, self.prom, self.run_id, self.tick = exp, kube, prom, run_id, tick
        self.rollbacks = []
        self.holds = []
        self.notes = []
        self.watched = [o["alert"] for o in exp["expectedObservations"]] + list(exp.get("mustNotFire", []))

    def labels(self):
        return {MANAGED: MANAGED_VALUE, RUN: self.run_id, EXPERIMENT: self.exp["name"]}

    def on_rollback(self, text, fn):
        self.rollbacks.append((text, fn))

    def must_hold(self, text, fn):
        """A check that the injection is still in place. When it stops being true, something else undid it and the run says so."""
        self.holds.append((text, fn))

    def wait(self, what, check, timeout):
        """Poll CHECK() every tick until it is true; False on timeout."""
        deadline = time.monotonic() + timeout
        while True:
            if check():
                return True
            if time.monotonic() >= deadline:
                self.notes.append("timed out after {}s waiting for {}".format(timeout, what))
                return False
            time.sleep(self.tick)


def label_args(labels):
    return ["{}={}".format(k, v) for k, v in labels.items()]


def pick_pods(run, target, count):
    """Ready pods matching the target, each checked against the blast radius (the cluster's answer is not trusted)."""
    pods = ready_pods(run.kube, target["namespace"], target["selector"])
    for p in pods:
        reason = run.kube.blast.permits("pod", p["metadata"]["namespace"], p["metadata"]["name"], p["metadata"].get("labels"))
        if reason:
            raise Refused("refused to act: {}".format(reason))
    pods.sort(key=lambda p: p["metadata"]["name"])
    if len(pods) < count:
        raise Refused("only {} ready pod(s) match {} in {}; the experiment needs {}".format(len(pods), target["selector"], target["namespace"], count))
    return pods[:count]


def inject_delete_pod(run):
    inj = run.exp["injection"]
    ns, sel = inj["target"]["namespace"], inj.get("readySelector") or inj["target"]["selector"]
    before = len(ready_pods(run.kube, ns, sel))
    pods = pick_pods(run, inj["target"], inj["count"])
    run.on_rollback("wait until {} pod(s) match {} in {} and are ready".format(before, sel, ns),
                    lambda: run.wait("{} ready pod(s)".format(before), lambda: len(ready_pods(run.kube, ns, sel)) >= before, run.exp["rollback"]["timeoutSeconds"]))
    for p in pods:
        m = p["metadata"]
        run.kube.mutate(["delete", "pod", m["name"], "-n", ns, "--wait=false"], "pod", ns, m["name"], m.get("labels"), "delete pod {}/{}".format(ns, m["name"]))


def workload(run, target):
    kind = target["kind"].lower()
    return kind, run.kube.read_json("get", kind, target["name"], "-n", target["namespace"])


def check_argocd(kube, obj, kind, ns, name):
    """A workload that Argo CD manages is put back by its self-heal within seconds, which would undo the experiment. The Application is read;
    it must not self-heal, or must be paused with the skip-reconcile annotation (chaos/README.md, "Argo CD")."""
    tracking = (obj["metadata"].get("annotations") or {}).get(ARGOCD_TRACKING)
    if not tracking:
        return
    app = tracking.split(":", 1)[0]
    argocd_ns = os.environ.get("CHAOS_ARGOCD_NAMESPACE", "argocd")
    try:
        application = kube.read_json("get", "application.argoproj.io", app, "-n", argocd_ns)
    except Refused as err:
        raise Refused("{} {}/{} is managed by the Argo CD Application {} and that cannot be read ({}), so it is not known whether it would be put back".format(kind, ns, name, app, err))
    self_heal = (((application.get("spec") or {}).get("syncPolicy") or {}).get("automated") or {}).get("selfHeal")
    paused = (application["metadata"].get("annotations") or {}).get(ARGOCD_SKIP) == "true"
    if self_heal and not paused:
        raise Refused("{} {}/{} is managed by the Argo CD Application {}, which self-heals: it would put the replica count back within seconds. "
                      "Pause the Application first (chaos/README.md, \"Argo CD\")".format(kind, ns, name, app))


def inject_scale_to_zero(run):
    t = run.exp["injection"]["target"]
    kind, obj = workload(run, t)
    ns, name = t["namespace"], t["name"]
    replicas = (obj.get("spec") or {}).get("replicas")
    if not replicas:
        raise Refused("{}/{} has no replicas to take away (spec.replicas is {})".format(ns, name, replicas))
    for hpa in run.kube.read_json("get", "hpa", "-n", ns)["items"]:
        ref = hpa["spec"].get("scaleTargetRef") or {}
        if ref.get("name") == name:
            raise Refused("{}/{} is scaled by the autoscaler {}, which would undo the experiment".format(ns, name, hpa["metadata"]["name"]))
    check_argocd(run.kube, obj, kind, ns, name)
    labels = (obj["metadata"].get("labels") or {})

    def restore():
        live = run.kube.read_json("get", kind, name, "-n", ns)
        meta = live["metadata"]
        annotation = (meta.get("annotations") or {}).get(ORIGINAL_REPLICAS)
        if annotation is None:
            return
        run.kube.mutate(["scale", kind, name, "-n", ns, "--replicas=" + annotation], kind, ns, name, meta.get("labels"), "restore {}/{} to {} replicas".format(ns, name, annotation))
        run.kube.mutate(["annotate", kind, name, "-n", ns, ORIGINAL_REPLICAS + "-"], kind, ns, name, meta.get("labels"), "remove the replica annotation of {}/{}".format(ns, name))
        run.kube.mutate(["label", kind, name, "-n", ns] + [k + "-" for k in (MANAGED, RUN, EXPERIMENT)], kind, ns, name, meta.get("labels"), "remove the chaos labels of {}/{}".format(ns, name))
        run.wait("{}/{} ready again".format(ns, name), lambda: ((run.kube.read_json("get", kind, name, "-n", ns).get("status") or {}).get("readyReplicas") or 0) >= int(annotation), run.exp["rollback"]["timeoutSeconds"])

    run.on_rollback("scale {}/{} back to {} replicas and remove the chaos labels".format(ns, name, replicas), restore)
    run.kube.mutate(["label", kind, name, "-n", ns, "--overwrite"] + label_args(run.labels()), kind, ns, name, labels, "label {}/{}".format(ns, name))
    run.kube.mutate(["annotate", kind, name, "-n", ns, "--overwrite", "{}={}".format(ORIGINAL_REPLICAS, replicas)], kind, ns, name, labels, "record the replicas of {}/{}".format(ns, name))
    run.kube.mutate(["scale", kind, name, "-n", ns, "--replicas=0"], kind, ns, name, labels, "scale {}/{} to zero".format(ns, name))
    run.must_hold("{}/{} is still at zero replicas".format(ns, name), lambda: ((run.kube.read_json("get", kind, name, "-n", ns).get("spec") or {}).get("replicas") or 0) == 0)


def inject_drain_node(run):
    inj = run.exp["injection"]
    ns, sel = inj["target"]["namespace"], inj["target"]["selector"]
    kube = run.kube
    pick_pods(run, inj["target"], 1)
    candidates = []
    for p in kube.read_json("get", "pods", "-n", ns, "-l", sel)["items"]:
        node = (p.get("spec") or {}).get("nodeName")
        if node and node not in candidates:
            candidates.append(node)
    candidates.sort()
    avoided = set()
    for a in inj.get("avoid", []):
        for p in kube.read_json("get", "pods", "-n", a["namespace"], "-l", a["selector"])["items"]:
            avoided.add((p.get("spec") or {}).get("nodeName"))
    chosen = []
    for node in candidates:
        if len(chosen) == inj["count"]:
            break
        if node in avoided:
            run.notes.append("node {} skipped: it runs a pod the experiment asks to avoid".format(node))
            continue
        # Everything the drain would evict must be inside the blast radius, in any namespace: the drain does not look at namespaces.
        on_node = kube.read_json("get", "pods", "-A", "--field-selector", "spec.nodeName=" + node)["items"]
        stray = []
        for p in on_node:
            owners = (p["metadata"].get("ownerReferences") or [])
            if any(o.get("kind") == "DaemonSet" for o in owners):
                continue
            if kube.blast.permits("pod", p["metadata"]["namespace"], p["metadata"]["name"], p["metadata"].get("labels")):
                stray.append("{}/{}".format(p["metadata"]["namespace"], p["metadata"]["name"]))
        if stray:
            run.notes.append("node {} skipped: it also runs pods outside the blast radius ({})".format(node, ", ".join(stray[:4])))
            continue
        chosen.append(node)
    if len(chosen) < inj["count"]:
        raise Refused("no node can be drained inside the blast radius ({} wanted, {} found); {}".format(
            inj["count"], len(chosen), "; ".join(run.notes[-3:]) or "no node runs a target pod"))
    ready_before = len(ready_pods(kube, ns, sel))
    for node in chosen:
        kube.blast.allow_node(node)

    def restore():
        for node in chosen:
            live = kube.read_json("get", "node", node)
            kube.mutate(["uncordon", node], "node", "", node, live["metadata"].get("labels"), "uncordon node {}".format(node))
            kube.mutate(["label", "node", node] + [k + "-" for k in (MANAGED, RUN, EXPERIMENT)], "node", "", node, live["metadata"].get("labels"), "remove the chaos labels of node {}".format(node))
        run.wait("{} ready pod(s) again".format(ready_before), lambda: len(ready_pods(kube, ns, sel)) >= ready_before, run.exp["rollback"]["timeoutSeconds"])

    run.on_rollback("uncordon {} and remove the chaos labels".format(", ".join(chosen)), restore)
    for node in chosen:
        live = kube.read_json("get", "node", node)
        kube.mutate(["label", "node", node, "--overwrite"] + label_args(run.labels()), "node", "", node, live["metadata"].get("labels"), "label node {}".format(node))
        kube.mutate(["cordon", node], "node", "", node, live["metadata"].get("labels"), "cordon node {}".format(node))
        kube.mutate(["drain", node, "--ignore-daemonsets", "--delete-emptydir-data", "--timeout={}s".format(inj["timeoutSeconds"])],
                    "node", "", node, live["metadata"].get("labels"), "drain node {}".format(node), timeout=inj["timeoutSeconds"] + 60)
    run.must_hold("node(s) {} still cordoned".format(", ".join(chosen)), lambda: all((kube.read_json("get", "node", n).get("spec") or {}).get("unschedulable") for n in chosen))


def policy_manifest(run, ns, direction):
    types = ["Ingress", "Egress"] if direction == "both" else [direction.capitalize()]
    meta_labels = run.labels()
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {"name": "chaos-deny-{}".format(run.run_id.lower()), "namespace": ns, "labels": meta_labels},
        "spec": {"podSelector": {"matchLabels": {ISOLATED: run.run_id}}, "policyTypes": types},
    }


def selects(selector, labels):
    """Does a NetworkPolicy podSelector select a pod with these labels?"""
    if not selector:
        return True
    ml = selector.get("matchLabels") or {}
    if any(labels.get(k) != v for k, v in ml.items()):
        return False
    for expr in selector.get("matchExpressions") or []:
        key, op, values = expr["key"], expr["operator"], expr.get("values") or []
        if op == "In" and labels.get(key) not in values:
            return False
        if op == "NotIn" and key in labels and labels[key] in values:
            return False
        if op == "Exists" and key not in labels:
            return False
        if op == "DoesNotExist" and key in labels:
            return False
    return True


def inject_network_deny(run):
    """A NetworkPolicy cannot take away what another policy allows: the rules add up. So the pod is moved out of the reach of the other
    policies instead. The deny policy goes in first (it selects nobody yet); then the pod loses its labels, which takes it out of its
    ReplicaSet (a new pod starts), out of the Service and out of every allow rule, and gives it the one label the deny policy selects."""
    inj = run.exp["injection"]
    ns, direction = inj["target"]["namespace"], inj["direction"]
    kube = run.kube
    pods = pick_pods(run, inj["target"], inj["count"])
    wanted = ["Ingress", "Egress"] if direction == "both" else [direction.capitalize()]
    new_labels = {ISOLATED: run.run_id}
    for np in kube.read_json("get", "networkpolicy", "-n", ns)["items"]:
        if (np["metadata"].get("labels") or {}).get(MANAGED) == MANAGED_VALUE:
            continue
        types = np["spec"].get("policyTypes") or ["Ingress"]
        if selects(np["spec"].get("podSelector"), new_labels) and any(t in types for t in wanted):
            raise Refused("the policy {}/{} would still select an isolated pod and add allow rules to it (an empty podSelector selects every pod); "
                          "a deny cannot override an allow".format(ns, np["metadata"]["name"]))
    manifest = policy_manifest(run, ns, direction)
    pname = manifest["metadata"]["name"]
    original = {}

    def restore():
        live = kube.read_json("get", "networkpolicy", "-n", ns, "-l", "{}={}".format(RUN, run.run_id))["items"]
        for np in live:
            kube.mutate(["delete", "networkpolicy", np["metadata"]["name"], "-n", ns], "networkpolicy", ns, np["metadata"]["name"], np["metadata"].get("labels"), "delete the deny policy {}".format(np["metadata"]["name"]))
        for p in kube.read_json("get", "pods", "-n", ns, "-l", "{}={}".format(ISOLATED, run.run_id))["items"]:
            m = p["metadata"]
            kube.mutate(["delete", "pod", m["name"], "-n", ns, "--wait=false"], "pod", ns, m["name"], m.get("labels"), "delete the isolated pod {}/{}".format(ns, m["name"]))
        run.wait("{} ready pod(s) again".format(before), lambda: len(ready_pods(kube, ns, run.exp["injection"]["target"]["selector"])) >= before, run.exp["rollback"]["timeoutSeconds"])

    before = len(ready_pods(kube, ns, inj["target"]["selector"]))
    run.on_rollback("delete the deny policy and the isolated pod(s), and wait for {} ready pod(s)".format(before), restore)
    kube.mutate(["apply", "-f", "-"], "networkpolicy", ns, pname, manifest["metadata"]["labels"], "apply the deny policy {}".format(pname), input_text=json.dumps(manifest))
    for p in pods:
        m = p["metadata"]
        labels = m.get("labels") or {}
        original[m["name"]] = labels
        args = ["label", "pod", m["name"], "-n", ns, "--overwrite"] + label_args(dict(run.labels(), **{ISOLATED: run.run_id})) + [k + "-" for k in labels if k not in run.labels()]
        kube.mutate(["annotate", "pod", m["name"], "-n", ns, "--overwrite", "{}={}".format(ORIGINAL_LABELS, json.dumps(labels, sort_keys=True))],
                    "pod", ns, m["name"], labels, "record the labels of pod {}/{}".format(ns, m["name"]))
        kube.mutate(args, "pod", ns, m["name"], labels, "isolate pod {}/{}".format(ns, m["name"]))
    run.must_hold("the deny policy {} is still there".format(pname), lambda: len(kube.read_json("get", "networkpolicy", "-n", ns, "-l", "{}={}".format(RUN, run.run_id))["items"]) >= 1)


INJECT = {
    "delete-pod": inject_delete_pod,
    "drain-node": inject_drain_node,
    "scale-to-zero": inject_scale_to_zero,
    "apply-network-deny": inject_network_deny,
}


def plan_lines(exp):
    inj = exp["injection"]
    t = inj["target"]
    where = "pods matching {} in {}".format(t["selector"], t["namespace"]) if "selector" in t else "{} {}/{}".format(t["kind"], t["namespace"], t["name"])
    what = {
        "delete-pod": "delete {} pod(s) among the {}".format(inj.get("count"), where),
        "drain-node": "cordon and drain {} node(s) that run the {} (every pod the drain would evict must be inside the blast radius)".format(inj.get("count"), where),
        "scale-to-zero": "scale {} to zero (the replica count is kept in an annotation)".format(where),
        "apply-network-deny": "isolate {} pod(s) among the {} ({} denied): a deny policy first, then the pod loses its labels".format(inj.get("count"), where, inj.get("direction")),
    }[inj["action"]]
    return what


# ---------------------------------------------------------------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------------------------------------------------------------

def current_context():
    proc = subprocess.run(["kubectl", "config", "current-context"], capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise Refused("kubectl has no current context")
    return proc.stdout.strip()


def check_cluster(context, pattern):
    name = cluster_name(context)
    if not re.search(pattern, name):
        raise Refused("the cluster {!r} does not match the pattern {} of the experiment: nothing was touched".format(name, pattern))
    return name


def print_plan(exp, cluster, matches):
    b, pre, inj = exp["blastRadius"], exp["preconditions"], exp["injection"]
    out("Experiment   {}{}".format(exp["name"], "  (the example: it exists to exercise the framework)" if exp.get("example") else ""))
    out("Hypothesis   {}".format(exp["hypothesis"]))
    out("Relates to   {}".format(", ".join("{} {}".format(r["type"], r["name"]) for r in exp["relatesTo"])))
    out("Cluster      {} ({} the pattern {})".format(cluster, "matches" if matches else "DOES NOT MATCH", pre["clusterNamePattern"]))
    out("Blast radius namespaces {}; selectors {}; at most {} pod(s) and {} node(s)".format(", ".join(b["namespaces"]), "; ".join(b["selectors"]), b["maxPods"], b["maxNodes"]))
    out("Preconditions  at least {} ready node(s); {}; no page alert firing; no leftover of an earlier run".format(
        pre["minReadyNodes"], "; ".join("{} {}/{} has {} ready replica(s)".format(r["kind"], r["namespace"], r["name"], r["count"]) for r in pre.get("minReplicas", [])) or "no replica minimum"))
    out("Steady state (before, during and after)")
    for p in exp["steadyState"]:
        out("  {} {} {} (no data: {})".format(p["name"], p["comparator"], p["threshold"], p.get("noData", "fail")))
        out("    {}".format(" ".join(p["query"].split())))
    out("Injection    {}: {}".format(inj["action"], plan_lines(exp)))
    out("Duration     {}s".format(exp["duration"]))
    out("Rollback     {} (waits up to {}s)".format(exp["rollback"]["action"], exp["rollback"]["timeoutSeconds"]))
    out("Abort        a probe failing for more than {}s, or any page alert, ends the run and rolls back at once".format(exp["abort"]["probeFailureGraceSeconds"]))
    out("Expected     {}".format(", ".join(o["alert"] for o in exp["expectedObservations"]) or "no alert is expected"))


def confirm(cluster):
    out("")
    out("This will change the cluster {}.".format(cluster))
    sys.stdout.write("Type the name of the cluster ({}) to go on: ".format(cluster))
    sys.stdout.flush()
    try:
        answer = sys.stdin.readline().strip()
    except OSError:
        answer = ""
    if answer != cluster:
        raise Refused("not confirmed: nothing was changed")
    out("")


def leftovers(kube, namespaces, values=(MANAGED_VALUE,)):
    """What earlier runs left: [(kind, namespace, name, labels, object)]. VALUES are the values of the managed-by label to look for: a run
    looks for its own (the load helper is expected to be there), --cleanup for both."""
    found = []
    for value in values:
        sel = "{}={}".format(MANAGED, value)
        for ns in namespaces:
            for kind, plural in (("networkpolicy", "networkpolicies"), ("deployment", "deployments"), ("statefulset", "statefulsets"), ("pod", "pods")):
                for o in kube.read_json("get", plural, "-n", ns, "-l", sel)["items"]:
                    found.append((kind, ns, o["metadata"]["name"], o["metadata"].get("labels") or {}, o))
        for o in kube.read_json("get", "nodes", "-l", sel)["items"]:
            found.append(("node", "", o["metadata"]["name"], o["metadata"].get("labels") or {}, o))
    return found


def check_preconditions(run):
    exp, kube = run.exp, run.kube
    pre = exp["preconditions"]
    nodes = kube.read_json("get", "nodes")["items"]
    ready = [n for n in nodes if any(c.get("type") == "Ready" and c.get("status") == "True" for c in (n.get("status") or {}).get("conditions") or [])
             and not (n.get("spec") or {}).get("unschedulable")]
    if len(ready) < pre["minReadyNodes"]:
        raise Refused("precondition: {} schedulable ready node(s), the experiment needs {}".format(len(ready), pre["minReadyNodes"]))
    for r in pre.get("minReplicas", []):
        obj = kube.read_json("get", r["kind"].lower(), r["name"], "-n", r["namespace"])
        have = (obj.get("status") or {}).get("readyReplicas") or 0
        if have < r["count"]:
            raise Refused("precondition: {} {}/{} has {} ready replica(s), the experiment needs {}".format(r["kind"], r["namespace"], r["name"], have, r["count"]))
    firing = page_alerts(run.prom)
    if firing:
        raise Refused("precondition: page alert(s) are firing: {}".format(", ".join(firing)))
    left = leftovers(kube, exp["blastRadius"]["namespaces"])
    if left:
        raise Refused("precondition: an earlier run left {} object(s) behind ({}); run chaos-run.sh --cleanup first".format(
            len(left), ", ".join("{} {}".format(k, n) for k, _, n, _, _ in left[:4])))


def probes_now(run, phase):
    """The probes that apply in PHASE (before, during or after); a probe without `phases` applies in all three."""
    return [evaluate_probe(run.prom, p) for p in run.exp["steadyState"] if phase in p.get("phases", ("before", "during", "after"))]


def describe(results):
    return ", ".join("{} {}{}".format(r["name"], r["state"], "" if r["value"] is None else " ({:.6g})".format(r["value"])) for r in results)


def watch(run, result):
    """Look at the probes every tick for the duration. Returns the reason to abort, or None."""
    exp = run.exp
    grace = exp["abort"]["probeFailureGraceSeconds"]
    end = time.monotonic() + exp["duration"]
    failing_since = {}
    seen = {a: [] for a in run.watched}
    started = time.monotonic()
    while time.monotonic() < end:
        time.sleep(run.tick)
        t = time.monotonic()
        for text, holds in run.holds:
            if not holds():
                result["invalid"] = True
                result["alerts"]["observed"] = seen
                return ("the injection was undone from outside after {:.0f}s ({} no more; something put it back, such as Argo CD self-heal): "
                        "the run proves nothing".format(t - started, text))
        results = probes_now(run, "during")
        result["probes"]["during"].append({"at": stamp(), "results": results})
        for r in results:
            if r["ok"]:
                failing_since.pop(r["name"], None)
            else:
                failing_since.setdefault(r["name"], t)
                if t - failing_since[r["name"]] >= grace:
                    result["alerts"]["observed"] = seen
                    return "probe {} failed for {:.0f}s (grace {}s): {}".format(r["name"], t - failing_since[r["name"]], grace, describe([r]))
        firing = page_alerts(run.prom)
        if firing:
            result["alerts"]["page"] = firing
            result["alerts"]["observed"] = seen
            return "page alert(s) firing: {}".format(", ".join(firing))
        observe(run, seen)
    result["alerts"]["observed"] = seen
    return None


def observe(run, seen):
    for alert in seen:
        try:
            states = sorted({m.get("alertstate", "?") for m, _ in run.prom.vector('ALERTS{{alertname="{}"}}'.format(alert))})
        except ProbeError:
            continue
        for s in states:
            if s not in seen[alert]:
                seen[alert].append(s)


def rollback_all(run, result):
    """Runs every registered rollback, last first, whatever happened. Signals are ignored meanwhile."""
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    steps = []
    ok = True
    t0 = time.monotonic()
    for text, fn in reversed(run.rollbacks):
        try:
            fn()
            steps.append({"step": text, "ok": True})
        except Exception as err:  # every step is tried, and each failure is recorded
            ok = False
            steps.append({"step": text, "ok": False, "error": str(err)})
    result["rollback"] = {"ok": ok, "seconds": round(time.monotonic() - t0, 1), "steps": steps}
    run.rollbacks = []
    return ok


def execute(exp, args):
    context = current_context()
    cluster = check_cluster(context, exp["preconditions"]["clusterNamePattern"])
    print_plan(exp, cluster, True)
    confirm(cluster)
    run_id = "{}-{}".format(now().strftime("%Y%m%dT%H%M%SZ"), secrets.token_hex(2))
    blast = Blast.of(exp)
    kube = Kube(context, blast)
    prom = Prometheus(context)
    tick = float(os.environ.get("CHAOS_TICK_SECONDS", "5"))
    run = Run(exp, kube, prom, run_id, tick)
    result = {
        "experiment": exp["name"], "example": bool(exp.get("example")), "runId": run_id, "cluster": cluster, "hypothesis": exp["hypothesis"],
        "relatesTo": exp["relatesTo"], "startedAt": stamp(), "phases": {}, "probes": {"before": [], "during": [], "after": []},
        "alerts": {"expected": [o["alert"] for o in exp["expectedObservations"]], "mustNotFire": list(exp.get("mustNotFire", [])), "observed": {}, "page": []},
        "invalid": False,
        "aborted": None, "injected": False, "rollback": None, "recovered": None, "hypothesisHeld": False, "notes": [],
    }
    status = 0
    interrupted = 0

    def on_signal(signum, _frame):
        raise Interrupted(signal.Signals(signum).name)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    def phase(name):
        result["phases"][name] = {"startedAt": stamp()}
        out("== " + name)

    try:
        prom.start()
        phase("preconditions")
        check_preconditions(run)
        phase("steady state before")
        before = probes_now(run, "before")
        result["probes"]["before"] = before
        out("  " + describe(before))
        if not all(r["ok"] for r in before):
            raise Refused("the steady state does not hold before the injection ({}); nothing was injected".format(describe([r for r in before if not r["ok"]])))
        phase("inject")
        result["injected"] = True
        INJECT[exp["injection"]["action"]](run)
        out("  injected: {}".format(plan_lines(exp)))
        phase("watch")
        reason = watch(run, result)
        if reason:
            result["aborted"] = {"reason": reason, "at": stamp()}
            out("  ABORT: " + reason)
    except Refused as err:
        if not run.rollbacks:
            # Nothing was registered, so nothing was changed: an ordinary refusal, not an aborted run.
            result["injected"] = False
            out("refused: {}".format(err))
            status = 1
        else:
            result["aborted"] = {"reason": "refused during the run: {}".format(err), "at": stamp()}
            out("  ABORT: {}".format(err))
    except Interrupted as err:
        result["aborted"] = {"reason": "interrupted by {}".format(err), "at": stamp()}
        interrupted = {"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129}.get(str(err), 130)
        out("  ABORT: interrupted by {}".format(err))
    except Exception as err:  # the rollback below still runs
        result["aborted"] = {"reason": "error during the run: {}".format(err), "at": stamp()}
        out("  ABORT: error during the run: {}".format(err))
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        if result["injected"]:
            phase("rollback")
            ok = rollback_all(run, result)
            for step in result["rollback"]["steps"]:
                out("  {} {}".format("ok  " if step["ok"] else "FAIL", step["step"] + ("" if step["ok"] else ": " + step["error"])))
            if not ok:
                out("ROLLBACK FAILED. Find what is left with: scripts/chaos-run.sh --cleanup")
                status = 1
            phase("steady state after")
            recovered = run.wait("the steady state to come back", lambda: all(r["ok"] for r in probes_now(run, "after")), exp["rollback"]["timeoutSeconds"])
            after = probes_now(run, "after") if prom.base else []
            result["probes"]["after"] = after
            result["recovered"] = bool(recovered and after and all(r["ok"] for r in after))
            out("  " + (describe(after) or "no probe could be read"))
            try:
                observe_final(run, result)
            except Exception as err:
                result["notes"].append("could not read the alerts at the end: {}".format(err))
            during_bad = any(not r["ok"] for d in result["probes"]["during"] for r in d["results"])
            if result["alerts"].get("forbidden"):
                result["notes"].append("alert(s) that must not fire did: {}".format(", ".join(result["alerts"]["forbidden"])))
            result["hypothesisHeld"] = bool(result["aborted"] is None and result["recovered"] and not during_bad and result["rollback"]["ok"]
                                            and not result["alerts"].get("forbidden") and not result["invalid"])
            result["notes"] += run.notes
            result["mutations"] = kube.mutations
            result["endedAt"] = stamp()
            write_result(result, args.results_dir)
            if status == 0 and not result["hypothesisHeld"]:
                status = 5 if result["invalid"] else 4
        prom.stop()
        if interrupted:
            status = interrupted
    if result["injected"]:
        out("")
        out("Hypothesis {}.".format("HELD" if result["hypothesisHeld"] else ("NOT PROVED: the injection was undone from outside (see the result file)" if result["invalid"] else "DID NOT HOLD (a finding: see the result file)")))
    return status


def observe_final(run, result):
    seen = result["alerts"]["observed"] or {a: [] for a in result["alerts"]["expected"]}
    observe(run, seen)
    result["alerts"]["observed"] = seen
    expected = result["alerts"]["expected"]
    result["alerts"]["fired"] = [a for a in expected if "firing" in seen.get(a, [])]
    result["alerts"]["missing"] = [a for a in expected if "firing" not in seen.get(a, [])]
    result["alerts"]["forbidden"] = [a for a in result["alerts"]["mustNotFire"] if "firing" in seen.get(a, [])]


def write_result(result, directory):
    os.makedirs(directory, exist_ok=True)
    base = os.path.join(directory, "{}-{}".format(result["experiment"], result["runId"]))
    with open(base + ".json", "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    held = result["hypothesisHeld"]
    lines = [
        "# {}{}".format(result["experiment"], " (example)" if result["example"] else ""),
        "",
        "- Run: `{}` on the cluster `{}`, {} to {}".format(result["runId"], result["cluster"], result["startedAt"], result.get("endedAt", "?")),
        "- Hypothesis: {}".format(result["hypothesis"]),
        "- Result: **{}**".format("the hypothesis held" if held else "the hypothesis did not hold (a finding)"),
        "- Aborted: {}".format(result["aborted"]["reason"] if result["aborted"] else "no"),
        "- Valid: {}".format("no: the injection was undone from outside" if result["invalid"] else "yes"),
        "- Rollback: {}".format("ok" if (result["rollback"] or {}).get("ok") else "FAILED"),
        "- Recovered: {}".format("yes" if result["recovered"] else "no"),
        "",
        "## Probes",
        "",
    ]
    for when in ("before", "after"):
        lines.append("- {}: {}".format(when, describe(result["probes"][when]) or "none"))
    during = [r for d in result["probes"]["during"] for r in d["results"]]
    lines.append("- during: {} reading(s), {} outside the threshold".format(len(during), sum(1 for r in during if not r["ok"])))
    lines += ["", "## Alerts", "",
              "- expected: {}".format(", ".join(result["alerts"]["expected"]) or "none"),
              "- fired: {}".format(", ".join(result["alerts"].get("fired", [])) or "none"),
              "- must not fire, and did: {}".format(", ".join(result["alerts"].get("forbidden", [])) or "none"),
              "- expected but not seen firing: {}".format(", ".join(result["alerts"].get("missing", [])) or "none"),
              "- page alerts at the abort: {}".format(", ".join(result["alerts"]["page"]) or "none"),
              "", "## Changes made", ""]
    lines += ["- {} {}".format(m["at"], m["what"]) for m in result.get("mutations", [])] or ["- none"]
    if result["notes"]:
        lines += ["", "## Notes", ""] + ["- " + n for n in result["notes"]]
    with open(base + ".md", "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    out("result written: {}.json and {}.md".format(base, base))


# ---------------------------------------------------------------------------------------------------------------------------------
# Cleanup.
# ---------------------------------------------------------------------------------------------------------------------------------

def cleanup(args):
    context = current_context()
    cluster = check_cluster(context, args.cluster_pattern)
    namespaces = args.namespace or ["shop"]
    blast = Blast(namespaces, [], [], cleanup=True)
    kube = Kube(context, blast)
    found = leftovers(kube, namespaces, (MANAGED_VALUE, LOAD_VALUE))
    out("Cluster {}; namespaces {}".format(cluster, ", ".join(namespaces)))
    if not found:
        out("No leftover of a chaos run.")
        return 0
    for kind, ns, name, labels, _ in found:
        out("  {} {}{} (run {}, experiment {})".format(kind, ns + "/" if ns else "", name, labels.get(RUN, "?"), labels.get(EXPERIMENT, "?")))
    if not args.execute:
        out("")
        out("Nothing was changed. To revert these: chaos-run.sh --cleanup --execute")
        return 0
    confirm(cluster)
    errors = 0
    for kind, ns, name, labels, obj in found:
        try:
            revert_leftover(kube, kind, ns, name, labels, obj)
            out("  reverted {} {}".format(kind, name))
        except (Refused, RuntimeError) as err:
            errors += 1
            out("  FAIL {} {}: {}".format(kind, name, err))
    return 1 if errors else 0


def revert_leftover(kube, kind, ns, name, labels, obj):
    ann = (obj["metadata"].get("annotations") or {})
    chaos = [k + "-" for k in (MANAGED, RUN, EXPERIMENT)]
    if kind == "networkpolicy":
        kube.mutate(["delete", "networkpolicy", name, "-n", ns], kind, ns, name, labels, "delete the leftover policy {}".format(name))
    elif kind == "pod":
        kube.mutate(["delete", "pod", name, "-n", ns, "--wait=false"], kind, ns, name, labels, "delete the leftover isolated pod {}".format(name))
    elif kind in ("deployment", "statefulset"):
        if ORIGINAL_REPLICAS in ann:
            kube.mutate(["scale", kind, name, "-n", ns, "--replicas=" + ann[ORIGINAL_REPLICAS]], kind, ns, name, labels, "restore the replicas of {}".format(name))
            kube.mutate(["annotate", kind, name, "-n", ns, ORIGINAL_REPLICAS + "-"], kind, ns, name, labels, "remove the replica annotation of {}".format(name))
        kube.mutate(["label", kind, name, "-n", ns] + chaos, kind, ns, name, labels, "remove the chaos labels of {}".format(name))
    elif kind == "node":
        kube.blast.allow_node(name)
        kube.mutate(["uncordon", name], kind, "", name, labels, "uncordon node {}".format(name))
        kube.mutate(["label", "node", name] + chaos, kind, "", name, labels, "remove the chaos labels of node {}".format(name))


# ---------------------------------------------------------------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(prog="chaos-run.sh", description="Run one chaos experiment (dry run by default).")
    parser.add_argument("experiment", nargs="*", help="the experiment file (or files, with --validate)")
    parser.add_argument("--execute", action="store_true", help="really do it, after typing the cluster name")
    parser.add_argument("--validate", action="store_true", help="only check the files against the schema")
    parser.add_argument("--cleanup", action="store_true", help="find (and with --execute revert) leftovers of earlier runs")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS)
    parser.add_argument("--namespace", action="append", help="cleanup: a namespace to look in (default shop)")
    parser.add_argument("--cluster-pattern", default=DEFAULT_CLEANUP_PATTERN, help="cleanup: the cluster name pattern (default {})".format(DEFAULT_CLEANUP_PATTERN))
    args = parser.parse_args(argv)
    if args.validate:
        if not args.experiment:
            parser.error("--validate needs at least one file")
        bad = 0
        for path in args.experiment:
            _, problems = load_experiment(path)
            for p in problems:
                out("  FAIL {}: {}".format(path, p))
            bad += 1 if problems else 0
            if not problems:
                out("  ok   {}".format(path))
        return 2 if bad else 0
    try:
        if args.cleanup:
            if args.experiment:
                parser.error("--cleanup takes no experiment file")
            return cleanup(args)
        if len(args.experiment) != 1:
            parser.error("give exactly one experiment file")
        exp, problems = load_experiment(args.experiment[0])
        if problems:
            for p in problems:
                out("  FAIL {}".format(p))
            return 2
        if not args.execute:
            context = current_context()
            name = cluster_name(context)
            matches = bool(re.search(exp["preconditions"]["clusterNamePattern"], name))
            print_plan(exp, name, matches)
            out("")
            if not matches:
                out("refused: the cluster {!r} does not match the pattern {} of the experiment".format(name, exp["preconditions"]["clusterNamePattern"]))
                return 1
            out("This was a dry run. Nothing was changed and the cluster was not read.")
            out("To run it for real: scripts/chaos-run.sh {} --execute".format(args.experiment[0]))
            return 0
        return execute(exp, args)
    except Refused as err:
        out("refused: {}".format(err))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
