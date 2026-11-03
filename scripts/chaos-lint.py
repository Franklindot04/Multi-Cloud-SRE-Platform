#!/usr/bin/env python3
"""Lints the chaos experiments against the platform they are written for (scripts/chaos-check.sh, scripts/chaos-tests.sh).

  chaos-lint.py --rules RENDER.yaml [--confirmed FILE] [--dashboards DIR] [--allow FILE] [--emit-promql OUT] EXPERIMENT.yaml...

RENDER.yaml is `helm template platform/observability/monitors`. The checks, on top of the schema (scripts/chaos-run.py --validate):

  - every metric name in a probe query is one the platform has: in the expression or the name of a rule, in the confirmed upstream list, in a
    dashboard, or in the allow list of the chaos folder (with a comment that says where it was confirmed)
  - every alert in expectedObservations and mustNotFire is an alert of the rules
  - the blast radius is no wider than the injection: its namespaces are the namespace of the target (a drain may list more, as
    anyPodInNamespaces, because it evicts what is on the node), each selector of it is part of the target's selector, its workloads are the
    target, and maxPods and maxNodes are the count of the injection
  - --emit-promql writes the probe queries as recording rules to OUT, for `promtool check rules` (a query that does not parse is found there)

Exit status 0 when everything is fine, 2 when something is not. Needs PyYAML.
"""

import argparse
import glob
import json
import os
import re
import sys

import yaml

yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

KEYWORDS = set("""
sum min max avg count group stddev stdvar topk bottomk quantile count_values rate irate increase delta idelta deriv predict_linear
histogram_quantile histogram_count histogram_sum histogram_fraction label_replace label_join vector scalar time timestamp abs ceil floor round
clamp clamp_min clamp_max exp ln log2 log10 sqrt sgn absent absent_over_time changes resets avg_over_time min_over_time max_over_time
sum_over_time count_over_time quantile_over_time stddev_over_time stdvar_over_time last_over_time present_over_time sort sort_desc sort_by_label
by without on ignoring group_left group_right and or unless bool offset inf nan day_of_week day_of_month days_in_month hour minute month year
""".split())


def metric_names(expr):
    """The metric names (and recording rule names) in a PromQL expression: what is left after strings, selectors, ranges, grouping lists and
    numbers are taken away, minus the functions and keywords."""
    e = re.sub(r'"(?:[^"\\]|\\.)*"|`[^`]*`', '""', expr)
    e = re.sub(r"\{[^}]*\}", "{}", e)
    e = re.sub(r"\[[^\]]*\]", "[]", e)
    e = re.sub(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", e)
    names = set()
    for m in re.finditer(r"[A-Za-z_:][A-Za-z0-9_:]*", e):
        if re.match(r"\d", e[m.start():m.start() + 1]):
            continue
        if m.group(0) in KEYWORDS:
            continue
        names.add(m.group(0))
    return names


def load_rules(path):
    alerts, names = set(), set()
    for d in yaml.safe_load_all(open(path, encoding="utf-8")):
        if not d or d.get("kind") != "PrometheusRule":
            continue
        for g in d["spec"]["groups"]:
            for r in g["rules"]:
                if r.get("alert"):
                    alerts.add(r["alert"])
                if r.get("record"):
                    names.add(r["record"])
                names |= metric_names(r["expr"])
    return alerts, names


def listed(path):
    out = set()
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line)
    return out


def dashboard_names(directory):
    out = set()
    for f in glob.glob(os.path.join(directory or "", "*.json")):
        def walk(node):
            if isinstance(node, dict):
                if isinstance(node.get("expr"), str):
                    out.update(metric_names(re.sub(r"\$\{?[A-Za-z_]+\}?", "x", node["expr"])))
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(json.load(open(f, encoding="utf-8")))
    return out


def parse_selector(text):
    return dict(pair.split("=", 1) for pair in text.split(","))


def lint(path, exp, known, alerts):
    problems = []

    def fail(message):
        problems.append("{}: {}".format(path, message))

    for p in exp["steadyState"]:
        for name in sorted(metric_names(p["query"]) - known):
            fail("probe {}: the metric {} is not in the rules, the confirmed list, a dashboard or chaos/metrics-allowlist.txt".format(p["name"], name))
    for key in ("expectedObservations", "mustNotFire"):
        for item in exp.get(key, []):
            alert = item["alert"] if isinstance(item, dict) else item
            if alert not in alerts:
                fail("{}: the alert {} is not an alert of the rules".format(key, alert))
    b, inj = exp["blastRadius"], exp["injection"]
    t = inj["target"]
    drain = inj["action"] == "drain-node"
    wide = set(b.get("anyPodInNamespaces", []))
    extra = sorted(set(b["namespaces"]) - {t["namespace"]} - (wide if drain else set()))
    if extra:
        fail("blastRadius.namespaces: {} is not a namespace of the target ({}){}".format(", ".join(extra), t["namespace"], "" if drain else "; only a drain may list more, as anyPodInNamespaces"))
    if wide and not drain:
        fail("blastRadius.anyPodInNamespaces: only a drain-node experiment evicts pods it did not select")
    if "selector" in t:
        wanted = parse_selector(t["selector"])
        for s in b["selectors"]:
            if not parse_selector(s).items() <= wanted.items():
                fail("blastRadius.selectors: {!r} is wider than the selector of the target ({!r})".format(s, t["selector"]))
    else:
        for s in b["selectors"]:
            pass
        extra_w = [w for w in b["workloads"] if w != {"kind": t["kind"], "name": t["name"]}]
        if extra_w:
            fail("blastRadius.workloads: {} is not the workload of the target ({}/{})".format(extra_w[0]["name"], t["kind"], t["name"]))
    if "selector" in t and b["workloads"]:
        fail("blastRadius.workloads: a pod action has no workload to change; leave the list empty")
    count = inj.get("count", 1)
    want_pods = count if inj["action"] in ("delete-pod", "apply-network-deny") else (1 if inj["action"] == "scale-to-zero" else 0)
    if b["maxPods"] != want_pods:
        fail("blastRadius.maxPods: {} is not what the injection touches ({})".format(b["maxPods"], want_pods))
    want_nodes = count if drain else 0
    if b["maxNodes"] != want_nodes:
        fail("blastRadius.maxNodes: {} is not what the injection touches ({})".format(b["maxNodes"], want_nodes))
    return problems


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", required=True)
    ap.add_argument("--confirmed")
    ap.add_argument("--dashboards")
    ap.add_argument("--allow")
    ap.add_argument("--emit-promql")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args(argv)
    alerts, rule_names = load_rules(a.rules)
    known = rule_names | listed(a.confirmed) | listed(a.allow) | dashboard_names(a.dashboards)
    problems, records = [], []
    for path in a.files:
        exp = yaml.safe_load(open(path, encoding="utf-8"))
        problems += lint(path, exp, known, alerts)
        for p in exp["steadyState"]:
            records.append({"record": "chaos:{}:{}".format(exp["name"].replace("-", "_"), p["name"].replace("-", "_")), "expr": " ".join(p["query"].split())})
    if a.emit_promql:
        with open(a.emit_promql, "w", encoding="utf-8") as handle:
            yaml.safe_dump({"groups": [{"name": "chaos-probes", "rules": records}]}, handle, sort_keys=False, width=100000)
    for p in problems:
        print("    FAIL " + p)
    if not problems:
        print("    {} experiment(s) are consistent with the rules, the metrics and their own blast radius".format(len(a.files)))
    return 2 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
