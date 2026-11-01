#!/usr/bin/env python3
"""Sends one trace to the OpenTelemetry Collector and looks for it in Tempo.

  scripts/trace-check.py TEMPO_URL COLLECTOR_URL

scripts/observability-check.sh starts Tempo and a collector from the images and the configuration the charts render,
with the container settings of the pods (a read-only root filesystem, no capabilities, a non-root user), and calls this.
The trace goes in as OTLP over HTTP to the collector, which exports it to Tempo over gRPC as the traces pipeline says;
it is then fetched from Tempo by its id. Tempo takes a few seconds to make a trace searchable, so the lookup retries.

Exit status: 0 the trace was found with its spans, 1 otherwise, 2 bad arguments.
"""

import json
import secrets
import sys
import time
import urllib.error
import urllib.request


def request(url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e).encode()


def wait(url, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if request(url)[0] == 200:
            return True
        time.sleep(2)
    return False


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    tempo, collector = argv[1].rstrip("/"), argv[2].rstrip("/")
    if not wait(tempo + "/ready", 90):
        print("    FAIL Tempo did not become ready within 90 seconds")
        return 1
    trace_id = secrets.token_hex(16)
    now = time.time_ns()
    spans = [
        {"traceId": trace_id, "spanId": secrets.token_hex(8), "name": name, "kind": 2,
         "startTimeUnixNano": str(now - 500_000_000), "endTimeUnixNano": str(now - 400_000_000 + i * 1_000_000)}
        for i, name in enumerate(("GET /readyz", "SELECT orders"))
    ]
    body = json.dumps({"resourceSpans": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "trace-check"}}]},
        "scopeSpans": [{"scope": {"name": "trace-check"}, "spans": spans}],
    }]}).encode("utf-8")
    # The collector may still be starting.
    deadline = time.time() + 60
    status = 0
    while time.time() < deadline:
        status, _ = request(collector + "/v1/traces", body, {"Content-Type": "application/json"})
        if status == 200:
            break
        time.sleep(2)
    if status != 200:
        print("    FAIL the collector answered {} to the trace".format(status))
        return 1
    deadline = time.time() + 60
    found = 0
    while time.time() < deadline:
        status, data = request("{}/api/traces/{}".format(tempo, trace_id), headers={"Accept": "application/json"})
        if status == 200:
            doc = json.loads(data.decode("utf-8"))
            found = sum(len(s.get("spans") or []) for b in (doc.get("batches") or doc.get("resourceSpans") or [])
                        for s in (b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []))
            if found:
                break
        time.sleep(2)
    if found != len(spans):
        print("    FAIL expected {} spans of trace {} in Tempo, found {} (last status {})".format(len(spans), trace_id, found, status))
        return 1
    print("    the trace {} arrived with {} spans".format(trace_id, found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
