#!/usr/bin/env python3
"""Check the security properties of rendered Kubernetes manifests.

Reads a multi-document YAML stream (the output of `helm template`) on stdin and fails, naming the offending
resource, when any workload or Job is not locked down:

  - every container must run as a non-root numeric user, forbid privilege escalation, drop all capabilities,
    set a seccomp profile, use a read-only root filesystem and set CPU and memory limits
  - no hostNetwork, hostPID, hostIPC, hostPath volume or privileged container
  - the service account token is not mounted, unless the pod is marked platform.example/api-access
  - no Service of type LoadBalancer or NodePort
  - no Secret with values, and no literal value for a variable that looks like a credential
  - images have a tag or digest, and the tag is not "latest"

Usage: helm template ... | rendered-security-check.py LABEL
"""

import re
import sys

import yaml

WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "Pod", "CronJob"}
CREDENTIAL_NAME = re.compile(r"(PASSWORD|SECRET|TOKEN|API_?KEY|CREDENTIAL)", re.IGNORECASE)


def pod_spec(doc):
    kind = doc["kind"]
    if kind == "Pod":
        return doc.get("spec", {}), doc.get("metadata", {})
    if kind == "CronJob":
        template = doc["spec"]["jobTemplate"]["spec"]["template"]
    else:
        template = doc["spec"]["template"]
    return template.get("spec", {}), template.get("metadata", {})


def check_container(c, pod_sc, problems, where):
    sc = c.get("securityContext") or {}
    name = c.get("name", "?")

    def fail(message):
        problems.append(f"{where} container {name}: {message}")

    if sc.get("privileged"):
        fail("is privileged")
    if sc.get("allowPrivilegeEscalation") is not False:
        fail("allowPrivilegeEscalation must be false")
    caps = sc.get("capabilities") or {}
    if "ALL" not in (caps.get("drop") or []):
        fail("must drop ALL capabilities")
    if caps.get("add"):
        fail(f"must not add capabilities ({', '.join(caps['add'])})")
    if sc.get("readOnlyRootFilesystem") is not True:
        fail("readOnlyRootFilesystem must be true")
    if not (sc.get("runAsNonRoot") is True or pod_sc.get("runAsNonRoot") is True):
        fail("runAsNonRoot must be true")
    uid = sc.get("runAsUser", pod_sc.get("runAsUser"))
    if not isinstance(uid, int) or uid == 0:
        fail("runAsUser must be a numeric non-root id")
    seccomp = (sc.get("seccompProfile") or pod_sc.get("seccompProfile") or {}).get("type")
    if seccomp not in ("RuntimeDefault", "Localhost"):
        fail("seccompProfile must be RuntimeDefault")
    limits = (c.get("resources") or {}).get("limits") or {}
    for resource in ("cpu", "memory"):
        if resource not in limits:
            fail(f"resources.limits.{resource} is required")
    if not (c.get("resources") or {}).get("requests"):
        fail("resources.requests is required")
    image = c.get("image", "")
    if "@sha256:" not in image:
        tag = image.rsplit(":", 1)[1] if ":" in image.rsplit("/", 1)[-1] else ""
        if not tag or tag == "latest":
            fail(f"image {image!r} needs a tag other than latest, or a digest")
    for env in c.get("env") or []:
        if "value" in env and CREDENTIAL_NAME.search(env["name"]) and not env["name"].endswith("_FILE"):
            fail(f"{env['name']} is set to a literal value; use a Secret")


def check_workload(doc, problems):
    where = f"{doc['kind']}/{doc['metadata']['name']}"
    spec, meta = pod_spec(doc)
    for flag in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(flag):
            problems.append(f"{where}: {flag} must not be set")
    for volume in spec.get("volumes") or []:
        if "hostPath" in volume:
            problems.append(f"{where}: volume {volume['name']} is a hostPath")
    annotations = meta.get("annotations") or {}
    if annotations.get("platform.example/api-access") != "true" and spec.get("automountServiceAccountToken") is not False:
        problems.append(f"{where}: automountServiceAccountToken must be false")
    pod_sc = spec.get("securityContext") or {}
    containers = (spec.get("containers") or []) + (spec.get("initContainers") or [])
    if not containers:
        problems.append(f"{where}: has no containers")
    for c in containers:
        check_container(c, pod_sc, problems, where)


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "manifest"
    problems = []
    count = 0
    for doc in yaml.safe_load_all(sys.stdin):
        if not doc:
            continue
        kind, name = doc.get("kind"), (doc.get("metadata") or {}).get("name", "?")
        if kind in WORKLOADS:
            count += 1
            check_workload(doc, problems)
        elif kind == "Service" and (doc.get("spec") or {}).get("type") in ("LoadBalancer", "NodePort"):
            problems.append(f"Service/{name}: type {doc['spec']['type']} is not allowed")
        elif kind == "Secret" and (doc.get("data") or doc.get("stringData")):
            problems.append(f"Secret/{name}: contains values")
    for problem in problems:
        print(f"    FAIL [{label}] {problem}", file=sys.stderr)
    if count == 0:
        print(f"    FAIL [{label}] no workload found to check", file=sys.stderr)
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
