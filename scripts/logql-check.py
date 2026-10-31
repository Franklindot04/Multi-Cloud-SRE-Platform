#!/usr/bin/env python3
"""Runs the LogQL of the Grafana dashboards against a running Loki, with a few sample log lines.

  scripts/logql-check.py LOKI_URL DASHBOARD_DIR

scripts/observability-check.sh starts a Loki container from the image the chart deploys, with the configuration the
chart renders, and calls this. The sample lines are pushed with the labels and the structured metadata that Alloy
sets (platform/observability/alloy): a JSON line with a lower-case level, a JSON line with an upper-case level (whose
metadata is lower case, as Alloy makes it) and plain text lines with no level. Then every Loki query of every dashboard
is run, with "All" selected and with concrete values, and a few of them are checked for what they return.

Exit status: 0 all queries parsed and returned what was expected, 1 otherwise, 2 bad arguments.
"""

import importlib.util
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load_contract_checker():
    spec = importlib.util.spec_from_file_location("chart_contract_check", os.path.join(HERE, "chart-contract-check.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def get(base, path, params):
    url = base + path + "?" + urllib.parse.urlencode(params, doseq=True)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode("utf-8", errors="replace")}


def wait_ready(base, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/ready", timeout=3) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(2)
    return False


def push(base, streams):
    body = json.dumps({"streams": streams}).encode("utf-8")
    request = urllib.request.Request(base + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30):
        pass


def sample_streams():
    now = time.time_ns()

    def lines(*items):
        # (age in seconds, text, level or None): the level goes in as structured metadata, as Alloy stores it. The
        # lines are 30 to 40 seconds old so that every step of a range query, and the one-minute window of an
        # instant query, covers them.
        out = []
        for age, text, level in items:
            entry = [str(now - age * 1_000_000_000), text]
            if level:
                entry.append({"level": level})
            out.append(entry)
        return out

    gateway = {"namespace": "shop", "pod": "gateway-6d9c-abcde", "container": "gateway", "app": "gateway", "service": "gateway"}
    payments = {"namespace": "shop", "pod": "payments-7f5b-fghij", "container": "payments", "app": "payments", "service": "payments"}
    # PostgreSQL pods have no app label, so the stream has none, and Loki derives service_name from the container.
    postgres = {"namespace": "data", "pod": "platform-pg-1", "container": "postgres"}
    return [
        {"stream": gateway, "values": lines(
            (39, '{"timestamp":"2026-10-31T01:00:00Z","level":"info","message":"request","service":"gateway"}', "info"),
            (38, '{"timestamp":"2026-10-31T01:00:01Z","level":"info","message":"started","service":"gateway"}', "info"),
            (37, '{"timestamp":"2026-10-31T01:00:02Z","level":"error","message":"upstream failed","service":"gateway"}', "error"),
        )},
        {"stream": payments, "values": lines(
            (36, '{"@timestamp":"2026-10-31T01:00:03Z","message":"Request","level":"INFO","level_value":20000}', "info"),
            (35, '{"@timestamp":"2026-10-31T01:00:04Z","message":"unhandled error","level":"ERROR","level_value":40000}', "error"),
        )},
        {"stream": postgres, "values": lines(
            (34, "LOG:  database system is ready to accept connections", None),
            (33, "LOG:  checkpoint starting: time", None),
        )},
    ]


def run_query(base, kind, expr):
    now = time.time()
    if kind == "selector":
        return get(base, "/loki/api/v1/series", {"match[]": expr, "start": int((now - 3600) * 1e9), "end": int(now * 1e9)})
    if kind == "instant":
        return get(base, "/loki/api/v1/query", {"query": expr, "time": int(now * 1e9)})
    return get(base, "/loki/api/v1/query_range", {"query": expr, "start": int((now - 600) * 1e9), "end": int(now * 1e9), "step": 15, "limit": 1000})


def streams_of(body):
    return (body.get("data") or {}).get("result") or []


def line_count(body):
    return sum(len(r.get("values") or []) for r in streams_of(body))


def label_values(body, key):
    return {r.get("metric", r.get("stream", {})).get(key) for r in streams_of(body)}


def scalar(body):
    result = streams_of(body)
    return float(result[0]["value"][1]) if result else 0.0


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    base, directory = argv[1].rstrip("/"), argv[2]
    contract = load_contract_checker()
    if not wait_ready(base, 90):
        print("    FAIL Loki did not become ready within 90 seconds")
        return 1
    push(base, sample_streams())
    failures = 0
    results = {}
    queries = contract.loki_queries(directory)
    for dashboard, title, expr, kind in queries:
        status, body = run_query(base, kind, expr)
        results[(dashboard, title)] = body
        if status != 200 or body.get("status") not in (None, "success"):
            failures += 1
            print("    FAIL {}: {}: Loki answered {} to {}: {}".format(dashboard, title, status, expr, json.dumps(body)[:300]))

    def expect(dashboard, title, label, ok):
        nonlocal failures
        if not ok:
            failures += 1
            print("    FAIL {}: {}: {}".format(dashboard, title, label))

    logs = "sre-logs.json"
    body = results.get((logs, "Log lines (all)"))
    if body is not None:
        # Loki returns a separate stream per value of the structured metadata, so the pods are counted, not the streams.
        pods = label_values(body, "pod")
        expect(logs, "Log lines (all)", "expected the 7 sample lines from 3 pods, got {} lines from {}".format(line_count(body), len(pods)),
               line_count(body) == 7 and len(pods) == 3)
    body = results.get((logs, "Log lines (concrete)"))
    if body is not None:
        expect(logs, "Log lines (concrete)", "expected the 2 lines with 'request' in the shop namespace (any case), got {}".format(line_count(body)),
               line_count(body) == 2)
    body = results.get((logs, "Error log lines per second, by service (all)"))
    if body is not None:
        names = label_values(body, "service_name")
        expect(logs, "Error log lines per second, by service (all)",
               "expected error series for gateway (lower-case level) and payments (upper-case level in the line) only, got {}".format(sorted(map(str, names))),
               names == {"gateway", "payments"})
    body = results.get((logs, "Log volume by service (all)"))
    if body is not None:
        names = label_values(body, "service_name")
        expect(logs, "Log volume by service (all)",
               "expected gateway, payments and postgres (service_name from the container for the pod without an app label), got {}".format(sorted(map(str, names))),
               names == {"gateway", "payments", "postgres"})
    body = results.get((logs, "Error lines per second (all)"))
    if body is not None:
        expect(logs, "Error lines per second (all)", "expected a rate above zero", scalar(body) > 0)
    for title, want in (("Services logging (all)", 3), ("Services logging (concrete)", 2), ("Pods logging (all)", 3)):
        body = results.get((logs, title))
        if body is not None:
            expect(logs, title, "expected {}, got {}".format(want, scalar(body)), scalar(body) == want)
    body = results.get((logs, "variable namespace (all)"))
    if body is not None:
        namespaces = {s.get("namespace") for s in body.get("data") or []}
        expect(logs, "variable namespace (all)", "expected the namespaces shop and data, got {}".format(sorted(map(str, namespaces))),
               namespaces == {"shop", "data"})

    # The level is structured metadata: it filters lines, and it is not a label.
    status, body = run_query(base, "range", '{namespace="shop"} | level="error"')
    expect("-", "level filter", "expected 2 error lines (gateway and payments), got {} (status {})".format(line_count(body), status),
           status == 200 and line_count(body) == 2)
    status, body = get(base, "/loki/api/v1/labels", {})
    expect("-", "labels", "the level must not be a label, got {}".format(body.get("data")), status == 200 and "level" not in (body.get("data") or []))
    # A selector that matches the empty value is refused by Loki, which is why the variables use .+ for All.
    status, _body = run_query(base, "range", '{namespace=~".*"}')
    expect("-", "empty-compatible selector", "expected Loki to refuse a selector that matches the empty value, status %s" % status, status == 400)

    print("    ran {} Loki queries from the dashboards".format(len(queries)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
