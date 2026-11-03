#!/usr/bin/env python3
"""A fake Prometheus for scripts/chaos-tests.sh, started by the fake kubectl in place of `kubectl port-forward`. It prints the line kubectl
prints ("Forwarding from 127.0.0.1:PORT -> 9090") and answers instant queries from the script in $FAKE_STATE/prom.json:

  {"probes": {"<text in the query>": [0.999, 0.999, null, "nan", 0.2]},   the answers to the next reads of a probe; null is no data, "nan"
                                                                         is NaN; the last answer repeats
   "page":   [[], [], ["SomeAlert"]],                                    the page alerts firing at each read of ALERTS{severity="page"}
   "alerts": {"HpaAtMaxReplicas": ["", "pending", "firing"]}}            the state of an alert at each read ("" is not there)

How far each list has been read is kept in $FAKE_STATE/prom-state.json. A query that matches nothing gets an error, so a probe the test
did not script is noticed. Every query is appended to $FAKE_STATE/prom.log.
"""

import http.server
import json
import os
import sys
import urllib.parse

STATE = os.environ["FAKE_STATE"]


def read_json(name, default):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as handle:
            return json.load(handle)
    except OSError:
        return default


def next_value(counter_key, values):
    counters = read_json("prom-state.json", {})
    i = counters.get(counter_key, 0)
    counters[counter_key] = i + 1
    with open(os.path.join(STATE, "prom-state.json"), "w", encoding="utf-8") as handle:
        json.dump(counters, handle)
    return values[min(i, len(values) - 1)]


def vector(samples):
    return {"status": "success", "data": {"resultType": "vector", "result": samples}}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
        with open(os.path.join(STATE, "prom.log"), "a", encoding="utf-8") as log:
            log.write(query + "\n")
        script = read_json("prom.json", {})
        body = None
        if query.startswith("ALERTS{"):
            if 'severity="page"' in query:
                names = next_value("page", script.get("page") or [[]])
                body = vector([{"metric": {"alertname": n, "alertstate": "firing", "severity": "page"}, "value": [0, "1"]} for n in names])
            else:
                name = query.split('alertname="', 1)[1].split('"', 1)[0]
                states = (script.get("alerts") or {}).get(name)
                state = next_value("alert:" + name, states) if states else ""
                body = vector([{"metric": {"alertname": name, "alertstate": state}, "value": [0, "1"]}] if state else [])
        else:
            for key, values in (script.get("probes") or {}).items():
                if key in query:
                    v = next_value("probe:" + key, values)
                    if v is None:
                        body = vector([])
                    else:
                        body = vector([{"metric": {}, "value": [0, "NaN" if v == "nan" else repr(float(v))]}])
                    break
        if body is None:
            body = {"status": "error", "errorType": "bad_data", "error": "fake prometheus: no script for this query: " + query[:80]}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("Forwarding from 127.0.0.1:{} -> 9090\n".format(server.server_address[1]))
sys.stdout.flush()
server.serve_forever()
