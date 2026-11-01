#!/usr/bin/env python3
"""Offline check of Kubernetes NetworkPolicy behaviour: do the rendered policies allow exactly the flows we intend?

It models the standard semantics of NetworkPolicy, reads the pods from the rendered workloads (and from the matrix, for
the pods that operators create), and evaluates every flow of a matrix file against the rendered policies. It proves that
the policies mean what we intend under the standard semantics. It does not prove that the network plugin (the VPC CNI
policy agent) behaves that way; that is for a cluster (docs/runbooks/network-policies.md).

The semantics that are modelled:

  - A pod is isolated for ingress (egress) once any policy in its namespace selects it and lists Ingress (Egress) in its
    policyTypes. A policy without policyTypes lists Ingress, and Egress too when it has an egress section.
  - What an isolated pod may do is the union of the rules of all the policies that select it. A pod that no policy
    isolates may do anything.
  - A flow is allowed only if the egress of the source allows it AND the ingress of the destination allows it. There is no
    special treatment for traffic inside a namespace. The kubelet's probes and port-forward do not use the pod network and are
    not modelled.
  - Peers: podSelector (matchLabels, matchExpressions In, NotIn, Exists, DoesNotExist) alone selects pods of the policy's
    namespace; namespaceSelector alone selects every pod of the namespaces whose labels match (the label
    kubernetes.io/metadata.name is always there); both in one peer select the pods that match the podSelector in those
    namespaces; ipBlock matches an address in the range and not in "except" (and applies to a pod's address too).
  - Ports: no ports (or an empty list) means every port and protocol; a rule port has a protocol (TCP by default) and an
    optional port, with endPort for a range; no port number means every port of that protocol. Named ports are not
    supported and stop the check.
  - An empty or missing from/to list means every peer; a missing ingress/egress section means no rule, which with the
    policy type means nothing is allowed.

Usage:
  network-policy-flows.py [--profile NAME] [--quiet] MATRIX NAMESPACE:FILE...

Each NAMESPACE:FILE is a rendered multi-document YAML file; documents that name no namespace get NAMESPACE. The matrix is
described in scripts/tests/fixtures/network-policies/README.md.
"""

import ipaddress
import sys

import yaml

# A bare "=" in a CRD (an enum value) is the YAML 1.1 "value" tag, which PyYAML cannot construct. Read it as text.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet", "Job")
METADATA_NAME = "kubernetes.io/metadata.name"


class ModelError(Exception):
    """The input cannot be evaluated (an unsupported field, an unknown name)."""


class Endpoint:
    """Something that traffic starts at or ends at: a pod or an address."""

    def __init__(self, key, namespace, labels, ip, is_pod, source):
        self.key = key
        self.namespace = namespace
        self.labels = labels
        self.ip = ipaddress.ip_address(ip)
        self.is_pod = is_pod
        self.source = source


# --- selectors and peers ---


def labels_match(selector, labels):
    """True if a label selector (matchLabels and matchExpressions) selects this label set. An empty selector selects all."""
    selector = selector or {}
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for expr in selector.get("matchExpressions") or []:
        key, op, values = expr["key"], expr["operator"], expr.get("values") or []
        if op == "In":
            if labels.get(key) not in values:
                return False
        elif op == "NotIn":
            if key in labels and labels[key] in values:
                return False
        elif op == "Exists":
            if key not in labels:
                return False
        elif op == "DoesNotExist":
            if key in labels:
                return False
        else:
            raise ModelError("unknown label selector operator {}".format(op))
    return True


def ip_in_block(ip, block):
    network = ipaddress.ip_network(block["cidr"], strict=False)
    if ip.version != network.version or ip not in network:
        return False
    for excluded in block.get("except") or []:
        if ip in ipaddress.ip_network(excluded, strict=False):
            return False
    return True


def peer_matches(peer, policy_namespace, other, namespaces):
    """True if this NetworkPolicyPeer matches the other endpoint of the flow."""
    if not peer:
        raise ModelError("a policy has an empty peer")
    if "ipBlock" in peer:
        return ip_in_block(other.ip, peer["ipBlock"])
    if not other.is_pod:
        return False
    if "namespaceSelector" in peer:
        if not labels_match(peer["namespaceSelector"], namespaces.get(other.namespace, {METADATA_NAME: other.namespace})):
            return False
    elif other.namespace != policy_namespace:
        return False
    if "podSelector" in peer and not labels_match(peer["podSelector"], other.labels):
        return False
    return True


def port_matches(rule_ports, port, protocol):
    if not rule_ports:
        return True
    for p in rule_ports:
        if (p.get("protocol") or "TCP") != protocol:
            continue
        number = p.get("port")
        if number is None:
            return True
        if isinstance(number, str):
            raise ModelError("named ports are not supported ({})".format(number))
        end = p.get("endPort", number)
        if number <= port <= end:
            return True
    return False


def policy_types(spec):
    types = spec.get("policyTypes")
    if types:
        return list(types)
    return ["Ingress"] + (["Egress"] if "egress" in spec else [])


# --- the model ---


class Model:
    def __init__(self):
        self.namespaces = {}
        self.endpoints = {}
        self.policies = []

    def policies_for(self, pod, direction):
        return [
            p
            for p in self.policies
            if p["metadata"]["namespace"] == pod.namespace
            and direction in policy_types(p.get("spec") or {})
            and labels_match((p.get("spec") or {}).get("podSelector"), pod.labels)
        ]

    def decide(self, pod, direction, other, port, protocol):
        """(isolated, allowing policy names) for the traffic of this pod in this direction."""
        selecting = self.policies_for(pod, direction)
        if not selecting:
            return False, []
        rule_key, peer_key = ("ingress", "from") if direction == "Ingress" else ("egress", "to")
        allowing = []
        for policy in selecting:
            for rule in (policy.get("spec") or {}).get(rule_key) or []:
                rule = rule or {}
                if not port_matches(rule.get("ports"), port, protocol):
                    continue
                peers = rule.get(peer_key)
                if not peers or any(peer_matches(p, pod.namespace, other, self.namespaces) for p in peers):
                    allowing.append(policy["metadata"]["name"])
                    break
        return True, allowing

    def evaluate(self, source, destination, port, protocol="TCP"):
        """Evaluate one flow. Returns (allowed, details) where details names what each side decided."""
        details = []
        allowed = True
        if source.is_pod:
            isolated, by = self.decide(source, "Egress", destination, port, protocol)
            ok = (not isolated) or bool(by)
            allowed = allowed and ok
            if not isolated:
                details.append(("egress of {}".format(source.key), "open: no policy isolates it", ok))
            elif by:
                details.append(("egress of {}".format(source.key), "allowed by " + ", ".join(sorted(set(by))), ok))
            else:
                details.append(("egress of {}".format(source.key), "blocked: no rule of the policies that isolate it allows it", ok))
        if destination.is_pod:
            isolated, by = self.decide(destination, "Ingress", source, port, protocol)
            ok = (not isolated) or bool(by)
            allowed = allowed and ok
            if not isolated:
                details.append(("ingress of {}".format(destination.key), "open: no policy isolates it", ok))
            elif by:
                details.append(("ingress of {}".format(destination.key), "allowed by " + ", ".join(sorted(set(by))), ok))
            else:
                details.append(("ingress of {}".format(destination.key), "blocked: no rule of the policies that isolate it allows it", ok))
        return allowed, details


def pod_labels_of(doc):
    labels = dict((((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {})
    if doc["kind"] == "Job":
        # The Job controller puts the name of the Job on its pods.
        name = doc["metadata"]["name"]
        labels["batch.kubernetes.io/job-name"] = name
        labels["job-name"] = name
    return labels


def load_manifests(entries):
    """entries: list of (namespace, path). Returns the documents, each with metadata.namespace filled in."""
    docs = []
    for namespace, path in entries:
        with open(path, encoding="utf-8") as handle:
            for doc in yaml.safe_load_all(handle):
                if not isinstance(doc, dict) or not doc.get("kind"):
                    continue
                if doc["kind"] in WORKLOADS + ("NetworkPolicy",):
                    doc.setdefault("metadata", {}).setdefault("namespace", namespace)
                docs.append(doc)
    return docs


def build_model(docs, matrix):
    """Build the model from rendered documents and the matrix. Returns (model, problems)."""
    problems = []
    model = Model()
    cidr = ipaddress.ip_network(matrix["vpcCidr"])
    addresses = iter(cidr.hosts())
    reserved = {ipaddress.ip_address(e["ip"]) for e in (matrix.get("endpoints") or {}).values()}

    def next_ip():
        for candidate in addresses:
            if candidate not in reserved and int(candidate) % 256 >= 100:
                return candidate
        raise ModelError("the VPC range of the matrix has no address left for pods")

    for name, extra in (matrix.get("namespaces") or {}).items():
        labels = {METADATA_NAME: name}
        labels.update(extra or {})
        model.namespaces[name] = labels

    rendered = {}
    for doc in docs:
        if doc["kind"] in WORKLOADS:
            key = "{}/{}".format(doc["metadata"]["namespace"], doc["metadata"]["name"])
            rendered[key] = (doc["metadata"]["namespace"], pod_labels_of(doc))
        elif doc["kind"] == "NetworkPolicy":
            model.policies.append(doc)
        elif doc["kind"] == "Namespace":
            model.namespaces.setdefault(doc["metadata"]["name"], {}).update(
                {METADATA_NAME: doc["metadata"]["name"], **((doc.get("metadata") or {}).get("labels") or {})}
            )

    declared = {}
    for entry in matrix.get("pods") or []:
        namespace, _, _ = entry["name"].partition("/")
        declared[entry["name"]] = (namespace, dict(entry.get("labels") or {}), entry.get("source", ""))

    # A declared pod that a chart also renders must carry labels the chart really puts on its pods.
    for key, (namespace, labels, _) in declared.items():
        if key in rendered:
            real = rendered[key][1]
            wrong = {k: v for k, v in labels.items() if real.get(k) != v}
            if wrong:
                problems.append("the matrix declares {} with labels the chart does not set: {}".format(key, wrong))

    pods = {}
    for key, (namespace, labels) in rendered.items():
        pods[key] = (namespace, labels, "rendered workload")
    for key, value in declared.items():
        if key not in rendered:
            pods[key] = value
    for key in sorted(pods):
        namespace, labels, source = pods[key]
        if namespace not in model.namespaces:
            model.namespaces[namespace] = {METADATA_NAME: namespace}
        model.endpoints[key] = Endpoint(key, namespace, labels, next_ip(), True, source)
    for name, entry in (matrix.get("endpoints") or {}).items():
        model.endpoints[name] = Endpoint(name, None, {}, entry["ip"], False, entry.get("source", ""))
    return model, problems


def resolve(model, matrix, name):
    key = (matrix.get("names") or {}).get(name, name)
    if key not in model.endpoints:
        raise ModelError("the flow names {}, which is not a pod or an endpoint".format(name))
    return model.endpoints[key]


def expand_flows(matrix, profile):
    """Expand the rows of the matrix into single flows: (source name, destination name, port, protocol, expect, note)."""
    flows = []
    for row in matrix.get("flows") or []:
        if profile not in (row.get("profiles") or ["data"]):
            continue
        sources = row["from"] if isinstance(row["from"], list) else [row["from"]]
        destinations = row["to"] if isinstance(row["to"], list) else [row["to"]]
        ports = row.get("ports") or [row["port"]]
        for source in sources:
            for destination in destinations:
                for port in ports:
                    flows.append((source, destination, int(port), row.get("protocol", "TCP"), row["expect"], row.get("note", "")))
    return flows


def check_flows(model, matrix, profile):
    """Evaluate the flows of the matrix. Returns (problems, allowed count, denied count)."""
    problems = []
    allowed_count = denied_count = 0
    for source_name, destination_name, port, protocol, expect, note in expand_flows(matrix, profile):
        source = resolve(model, matrix, source_name)
        destination = resolve(model, matrix, destination_name)
        allowed, details = model.evaluate(source, destination, port, protocol)
        if expect == "allow":
            allowed_count += 1
        elif expect == "deny":
            denied_count += 1
        else:
            raise ModelError("a flow expects {}, not allow or deny".format(expect))
        if allowed == (expect == "allow"):
            continue
        flow = "{} -> {}:{}/{}".format(source_name, destination_name, port, protocol)
        if expect == "allow":
            blockers = [d for d in details if not d[2]]
            problems.append(
                "flow {} should be allowed but is blocked: {} ({})".format(
                    flow, "; ".join("{} {}".format(who, why) for who, why, _ in blockers), note
                )
            )
        else:
            problems.append(
                "flow {} should be denied but is allowed: {} ({})".format(
                    flow, "; ".join("{} {}".format(who, why) for who, why, _ in details), note
                )
            )
    return problems, allowed_count, denied_count


def check_isolation(model, matrix):
    """Every pod of the namespaces listed under "enforced" is isolated for ingress and egress."""
    problems = []
    for key, endpoint in sorted(model.endpoints.items()):
        if not endpoint.is_pod or endpoint.namespace not in (matrix.get("enforced") or []):
            continue
        for direction in ("Ingress", "Egress"):
            if not model.policies_for(endpoint, direction):
                problems.append("{} is not isolated for {}: no policy selects it".format(key, direction.lower()))
    return problems


def run(matrix, docs, profile):
    """Returns (problems, allowed count, denied count)."""
    model, problems = build_model(docs, matrix)
    flow_problems, allowed_count, denied_count = check_flows(model, matrix, profile)
    return problems + check_isolation(model, matrix) + flow_problems, allowed_count, denied_count


def main(argv):
    args = argv[1:]
    profile = "data"
    quiet = False
    while args and args[0].startswith("--"):
        option = args.pop(0)
        if option == "--profile":
            profile = args.pop(0)
        elif option == "--quiet":
            quiet = True
        else:
            print(__doc__, file=sys.stderr)
            return 2
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(args[0], encoding="utf-8") as handle:
        matrix = yaml.safe_load(handle)
    entries = []
    for item in args[1:]:
        namespace, _, path = item.partition(":")
        entries.append((namespace, path))
    try:
        problems, allowed_count, denied_count = run(matrix, load_manifests(entries), profile)
    except ModelError as error:
        print("    FAIL {}".format(error))
        return 1
    for problem in problems:
        print("    FAIL " + problem)
    if not quiet:
        print(
            "    profile {}: {} flows evaluated, {} expected allowed and {} expected denied".format(
                profile, allowed_count + denied_count, allowed_count, denied_count
            )
        )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
