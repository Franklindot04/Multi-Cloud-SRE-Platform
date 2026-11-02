#!/usr/bin/env python3
"""Inputs for the Kyverno tests of the admission policies (scripts/policy-check.sh).

  policy-test-inputs.py policies POLICIES_YAML OUT_FILE
      writes the policies without the ImageValidatingPolicy: it verifies signatures against the registry and the Sigstore services,
      which an offline test cannot reach (the policy is checked by scripts/chart-contract-check.py policies, and loaded by
      kyverno apply against a pod that it does not match)

  policy-test-inputs.py reality OUT_DIR LABEL=FILE...
      reads rendered manifests (the service chart under every profile, the RabbitMQ credentials chart), keeps the workloads, puts
      them in the shop namespace under the name LABEL--NAME, and writes OUT_DIR/resources.yaml and OUT_DIR/kyverno-test.yaml. The
      test expects every workload to pass every policy that applies to it (a workload with the exempt label is skipped), which is what
      keeps the policies from blocking our own workloads.
"""

import sys

import yaml

yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod")
CONTROLLERS = ("Deployment", "StatefulSet", "DaemonSet")
POD_POLICIES = ["require-image-digest", "restrict-image-registries", "require-resources", "require-app-name-label"]
EXEMPT = "platform.example/policy-exempt"


def policies(src, out):
    docs = [d for d in yaml.safe_load_all(open(src, encoding="utf-8")) if d and d.get("kind") != "ImageValidatingPolicy"]
    with open(out, "w", encoding="utf-8") as handle:
        yaml.safe_dump_all(docs, handle, sort_keys=False)
    print("{} policies".format(len(docs)))


def exempt(doc):
    return (doc.get("metadata", {}).get("labels") or {}).get(EXEMPT) == "true"


def reality(out_dir, entries):
    resources = []
    results = {}
    for entry in entries:
        label, _, path = entry.partition("=")
        for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
            if not doc or doc.get("kind") not in WORKLOADS:
                continue
            doc["metadata"]["namespace"] = "shop"
            doc["metadata"]["name"] = "{}--{}".format(label, doc["metadata"]["name"])
            resources.append(doc)
            name = doc["metadata"]["name"]
            result = "skip" if exempt(doc) else "pass"
            for policy in POD_POLICIES:
                results.setdefault((policy, result), []).append(name)
            if doc["kind"] in CONTROLLERS:
                results.setdefault(("require-probes", result), []).append(name)
    with open(out_dir + "/resources.yaml", "w", encoding="utf-8") as handle:
        yaml.safe_dump_all(resources, handle, sort_keys=False)
    expected = [
        {"policy": policy, "isValidatingPolicy": True, "resources": names, "result": result}
        for (policy, result), names in sorted(results.items())
    ]
    test = {
        "apiVersion": "cli.kyverno.io/v1alpha1",
        "kind": "Test",
        "metadata": {"name": "rendered-workloads"},
        "policies": ["policies.yaml"],
        "resources": ["resources.yaml"],
        "results": expected,
    }
    with open(out_dir + "/kyverno-test.yaml", "w", encoding="utf-8") as handle:
        yaml.safe_dump(test, handle, sort_keys=False)
    print("{} workloads from {} renders".format(len(resources), len(entries)))
    return 0 if resources else 1


def main(argv):
    if len(argv) == 4 and argv[1] == "policies":
        policies(argv[2], argv[3])
        return 0
    if len(argv) >= 4 and argv[1] == "reality":
        return reality(argv[2], argv[3:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
