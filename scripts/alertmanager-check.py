#!/usr/bin/env python3
"""Sends test alerts to a running Alertmanager and checks where they go and which are hidden.

  scripts/alertmanager-check.py ALERTMANAGER_URL

scripts/observability-check.sh starts an Alertmanager container from the image the stack deploys, with the
configuration the stack renders, and calls this. Six alerts are posted to the API and read back:

  - a page alert for an SLO goes to the receiver page
  - a ticket alert of the same slo and service is hidden by it (inhibited)
  - a ticket alert of another slo goes to the receiver ticket
  - ServiceTargetDown for a service goes to the receiver page
  - a burn-rate alert of the same service is hidden by it
  - an alert with another severity goes to the receiver default

Exit status: 0 every alert went where it should, 1 otherwise, 2 bad arguments.
"""

import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def call(base, path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"} if data else {}
    request = urllib.request.Request(base + path, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        text = response.read().decode("utf-8")
        return json.loads(text) if text else None


def wait_ready(base, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/-/ready", timeout=3) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    return False


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    base = argv[1].rstrip("/")
    if not wait_ready(base, 60):
        print("    FAIL Alertmanager did not become ready within 60 seconds")
        return 1
    now = datetime.now(timezone.utc)
    stamp = {"startsAt": now.isoformat(), "endsAt": (now + timedelta(minutes=10)).isoformat()}

    def alert(**labels):
        return {"labels": labels, **stamp}

    sent = {
        "page": alert(alertname="SLOBurnRatePageFast", severity="page", slo="gateway-availability", service="gateway"),
        "ticket, same slo": alert(alertname="SLOBurnRateTicketFast", severity="ticket", slo="gateway-availability", service="gateway"),
        "ticket, other slo": alert(alertname="SLOBurnRateTicketFast", severity="ticket", slo="gateway-latency", service="gateway"),
        "target down": alert(alertname="ServiceTargetDown", severity="page", service="orders", job="orders"),
        "burn, same service": alert(alertname="SLOBurnRatePageSlow", severity="page", slo="gateway-availability", service="orders"),
        "other severity": alert(alertname="SomethingElse", severity="warning", service="payments"),
    }
    call(base, "/api/v2/alerts", list(sent.values()))
    time.sleep(2)
    got = call(base, "/api/v2/alerts?active=true&silenced=true&inhibited=true&unprocessed=true")
    failures = 0

    def find(name):
        want = sent[name]["labels"]
        for a in got:
            if all(a["labels"].get(k) == v for k, v in want.items()):
                return a
        return None

    expectations = (
        ("page", "active", ["page"]),
        ("ticket, same slo", "suppressed", None),
        ("ticket, other slo", "active", ["ticket"]),
        ("target down", "active", ["page"]),
        ("burn, same service", "suppressed", None),
        ("other severity", "active", ["default"]),
    )
    for name, state, receivers in expectations:
        a = find(name)
        if a is None:
            failures += 1
            print("    FAIL the alert '{}' is not in the Alertmanager API".format(name))
            continue
        status = a["status"]
        if status["state"] != state:
            failures += 1
            print("    FAIL '{}': expected state {}, got {} (inhibited by {})".format(name, state, status["state"], status.get("inhibitedBy")))
        elif state == "suppressed" and not status.get("inhibitedBy"):
            failures += 1
            print("    FAIL '{}' is suppressed but not by an inhibition".format(name))
        elif receivers is not None and [r["name"] for r in a["receivers"]] != receivers:
            failures += 1
            print("    FAIL '{}': expected receivers {}, got {}".format(name, receivers, [r["name"] for r in a["receivers"]]))
    print("    sent {} alerts and checked their receivers and inhibitions".format(len(sent)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
