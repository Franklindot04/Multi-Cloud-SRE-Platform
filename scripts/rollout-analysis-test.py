#!/usr/bin/env python3
"""Builds the promtool test file for the queries of the canary analysis (scripts/observability-check.sh).

  rollout-analysis-test.py ROLLOUT_RENDER TEST_TEMPLATE OUT_FILE

reads the rendered AnalysisTemplate from ROLLOUT_RENDER (the service chart with rollout.enabled and rollout.analysis.enabled), and writes
TEST_TEMPLATE (deploy/helm/tests/analysis-queries.test.yaml) to OUT_FILE with the real queries in place of the markers __SUCCESS_RATIO__
and __FAST_RATIO__, the analysis argument canary-hash replaced by abc123, and the thresholds of the conditions in place of
__SUCCESS_THRESHOLD__ and __FAST_THRESHOLD__. The tests therefore run the queries the controller runs, not copies of them.
"""

import re
import sys

import yaml

HASH = "abc123"


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    docs = [d for d in yaml.safe_load_all(open(argv[1], encoding="utf-8")) if d]
    templates = [d for d in docs if d["kind"] == "AnalysisTemplate"]
    if len(templates) != 1:
        print("expected one AnalysisTemplate in {}, found {}".format(argv[1], len(templates)), file=sys.stderr)
        return 1
    metrics = {m["name"]: m for m in templates[0]["spec"]["metrics"]}
    marks = {}
    for marker, name in (("SUCCESS", "success-ratio"), ("FAST", "fast-ratio")):
        metric = metrics[name]
        marks["__{}_RATIO__".format(marker)] = metric["provider"]["prometheus"]["query"].strip().replace("{{args.canary-hash}}", HASH)
        marks["__{}_THRESHOLD__".format(marker)] = re.fullmatch(r"result\[0\] >= ([0-9.]+)", metric["successCondition"]).group(1)
    text = open(argv[2], encoding="utf-8").read()
    for marker, value in sorted(marks.items(), key=lambda kv: -len(kv[0])):
        text = text.replace(marker, value)
    open(argv[3], "w", encoding="utf-8").write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
