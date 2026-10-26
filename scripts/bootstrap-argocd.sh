#!/usr/bin/env bash
# Bootstrap Argo CD on the EKS hub cluster.
#
# Installs Argo CD from platform/argocd/install, records the cluster's identifiers as labels and
# annotations on the in-cluster Argo CD cluster secret (so they never appear in Git), then applies
# the AppProjects and the root Application, which deploys everything else from Git.
#
# Identifiers come from the Terraform outputs of infra/terraform/environments/aws:
#   cluster_name, region, account_id, vpc_id, aws_load_balancer_controller_role_arn
# and, when present, external_dns_role_arn, cert_manager_role_arn and dns_zone_id.
#
# Nothing is written to disk except a temporary Helm cache that is removed on exit, and no secret
# value is printed. With --dry-run nothing is read from or changed in any cluster or cloud account.
set -euo pipefail

usage() {
  cat << 'EOF'
Usage: scripts/bootstrap-argocd.sh --context CONTEXT [options]

Required:
  --context CONTEXT        kubectl context of the hub cluster (never defaults to the current one)

Options:
  --dry-run                print what would be done and change nothing
  --yes                    do not ask for confirmation
  --terraform-dir DIR      Terraform root stack to read outputs from
                           (default: infra/terraform/environments/aws)
  --enable-external-dns    label the cluster so external-dns is deployed (needs --dns-domain and
                           the external_dns_role_arn Terraform output)
  --dns-domain DOMAIN      domain external-dns may manage, for example example.com
  --enable-dns01           label the cluster so the Let's Encrypt DNS-01 issuer is created
                           (needs --acme-email and a Route 53 hosted zone)
  --acme-email EMAIL       contact address for the ACME account
  --hosted-zone-id ID      Route 53 hosted zone ID (defaults to the dns_zone_id Terraform output)
  -h, --help               show this help
EOF
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

CONTEXT=""
DRY_RUN=0
ASSUME_YES=0
ENABLE_EXTERNAL_DNS=0
ENABLE_DNS01=0
DNS_DOMAIN=""
ACME_EMAIL=""
HOSTED_ZONE_ID=""
TF_DIR="infra/terraform/environments/aws"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      [ "$#" -ge 2 ] || die "--context needs a value"
      CONTEXT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --terraform-dir)
      [ "$#" -ge 2 ] || die "--terraform-dir needs a value"
      TF_DIR="$2"
      shift 2
      ;;
    --enable-external-dns)
      ENABLE_EXTERNAL_DNS=1
      shift
      ;;
    --dns-domain)
      [ "$#" -ge 2 ] || die "--dns-domain needs a value"
      DNS_DOMAIN="$2"
      shift 2
      ;;
    --enable-dns01)
      ENABLE_DNS01=1
      shift
      ;;
    --acme-email)
      [ "$#" -ge 2 ] || die "--acme-email needs a value"
      ACME_EMAIL="$2"
      shift 2
      ;;
    --hosted-zone-id)
      [ "$#" -ge 2 ] || die "--hosted-zone-id needs a value"
      HOSTED_ZONE_ID="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$CONTEXT" ] || {
  usage >&2
  die "--context is required: this script never uses the current kubectl context implicitly"
}

# Run from the repository root so relative paths work wherever the script is called from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

INSTALL_DIR="platform/argocd/install"
BOOTSTRAP_DIR="platform/argocd/bootstrap"
[ -f "$INSTALL_DIR/Chart.lock" ] || die "$INSTALL_DIR/Chart.lock is missing"
[ -d "$BOOTSTRAP_DIR" ] || die "$BOOTSTRAP_DIR is missing"

# --- prerequisites ---

missing=""
for tool in kubectl helm aws jq terraform; do
  command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "missing tools (needed for a real run):$missing"
  else
    die "missing required tools:$missing"
  fi
fi

if [ "$ENABLE_EXTERNAL_DNS" -eq 1 ] && [ -z "$DNS_DOMAIN" ]; then
  die "--enable-external-dns needs --dns-domain"
fi
if [ "$ENABLE_DNS01" -eq 1 ] && [ -z "$ACME_EMAIL" ]; then
  die "--enable-dns01 needs --acme-email"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run: nothing will be read from or changed in any cluster, cloud account or Terraform state"
fi

# Run a command, or only print it in dry-run mode.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- identifiers from Terraform ---

CLUSTER_NAME=""
REGION=""
ACCOUNT_ID=""
VPC_ID=""
LBC_ROLE_ARN=""
EXTERNAL_DNS_ROLE_ARN=""
CERT_MANAGER_ROLE_ARN=""

tf_value() {
  # tf_value NAME prints the output value, or nothing when it is missing or null.
  printf '%s' "$TF_JSON" | jq -r --arg n "$1" '.[$n].value // empty'
}

require_match() {
  # require_match LABEL VALUE REGEX
  printf '%s' "$2" | grep -Eq "$3" || die "Terraform output $1 has an unexpected format"
}

if [ "$DRY_RUN" -eq 1 ]; then
  info "would read outputs from $TF_DIR with: terraform -chdir=$TF_DIR output -json"
  CLUSTER_NAME="<cluster_name>"
  REGION="<region>"
  ACCOUNT_ID="<account_id>"
  VPC_ID="<vpc_id>"
  LBC_ROLE_ARN="<aws_load_balancer_controller_role_arn>"
  EXTERNAL_DNS_ROLE_ARN="<external_dns_role_arn>"
  CERT_MANAGER_ROLE_ARN="<cert_manager_role_arn>"
  [ -n "$HOSTED_ZONE_ID" ] || HOSTED_ZONE_ID="<dns_zone_id>"
else
  info "reading Terraform outputs from $TF_DIR"
  TF_JSON="$(terraform -chdir="$TF_DIR" output -json)" || die "could not read Terraform outputs (is the stack initialised and applied?)"

  CLUSTER_NAME="$(tf_value cluster_name)"
  REGION="$(tf_value region)"
  ACCOUNT_ID="$(tf_value account_id)"
  VPC_ID="$(tf_value vpc_id)"
  LBC_ROLE_ARN="$(tf_value aws_load_balancer_controller_role_arn)"
  EXTERNAL_DNS_ROLE_ARN="$(tf_value external_dns_role_arn)"
  CERT_MANAGER_ROLE_ARN="$(tf_value cert_manager_role_arn)"
  [ -n "$HOSTED_ZONE_ID" ] || HOSTED_ZONE_ID="$(tf_value dns_zone_id)"

  [ -n "$CLUSTER_NAME" ] || die "Terraform output cluster_name is empty"
  [ -n "$REGION" ] || die "Terraform output region is empty"
  [ -n "$ACCOUNT_ID" ] || die "Terraform output account_id is empty"
  [ -n "$VPC_ID" ] || die "Terraform output vpc_id is empty"
  [ -n "$LBC_ROLE_ARN" ] || die "Terraform output aws_load_balancer_controller_role_arn is empty (is enable_load_balancer_controller_iam true?)"

  require_match cluster_name "$CLUSTER_NAME" '^[a-z][a-z0-9-]{1,38}[a-z0-9]$'
  require_match region "$REGION" '^[a-z]{2}(-[a-z]+)+-[0-9]$'
  require_match account_id "$ACCOUNT_ID" '^[0-9]{12}$'
  require_match vpc_id "$VPC_ID" '^vpc-[0-9a-f]+$'
  role_re='^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$'
  require_match aws_load_balancer_controller_role_arn "$LBC_ROLE_ARN" "$role_re"
  [ -z "$EXTERNAL_DNS_ROLE_ARN" ] || require_match external_dns_role_arn "$EXTERNAL_DNS_ROLE_ARN" "$role_re"
  [ -z "$CERT_MANAGER_ROLE_ARN" ] || require_match cert_manager_role_arn "$CERT_MANAGER_ROLE_ARN" "$role_re"
  [ -z "$HOSTED_ZONE_ID" ] || require_match dns_zone_id "$HOSTED_ZONE_ID" '^Z[A-Z0-9]+$'
fi

if [ "$ENABLE_EXTERNAL_DNS" -eq 1 ] && [ -z "$EXTERNAL_DNS_ROLE_ARN" ]; then
  die "--enable-external-dns needs the external_dns_role_arn Terraform output (set enable_external_dns_iam = true and apply)"
fi
if [ "$ENABLE_DNS01" -eq 1 ]; then
  [ -n "$CERT_MANAGER_ROLE_ARN" ] || die "--enable-dns01 needs the cert_manager_role_arn Terraform output (set enable_cert_manager_iam = true and apply)"
  [ -n "$HOSTED_ZONE_ID" ] || die "--enable-dns01 needs a hosted zone (--hosted-zone-id or the dns_zone_id output)"
fi

# --- confirm the target cluster ---

if [ "$DRY_RUN" -eq 1 ]; then
  info "would confirm that kubectl context '$CONTEXT' exists and points at the EKS cluster from Terraform,"
  info "and that the AWS credentials belong to the account from Terraform"
else
  kubectl config get-contexts -o name | grep -Fxq -- "$CONTEXT" || die "kubectl context '$CONTEXT' does not exist"
  server="$(kubectl config view --minify --context "$CONTEXT" -o 'jsonpath={.clusters[0].cluster.server}')"
  eks_endpoint="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query cluster.endpoint --output text)"
  [ "$server" = "$eks_endpoint" ] || die "context '$CONTEXT' points at $server, which is not the EKS cluster '$CLUSTER_NAME' ($eks_endpoint)"
  caller_account="$(aws sts get-caller-identity --query Account --output text)"
  [ "$caller_account" = "$ACCOUNT_ID" ] || die "AWS credentials are for a different account than the Terraform stack"

  info "target: cluster '$CLUSTER_NAME' in $REGION via context '$CONTEXT'"
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Install Argo CD on this cluster? [y/N] '
    read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *) die "aborted" ;;
    esac
  fi
fi

# --- install Argo CD ---

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HELM_CONFIG_HOME="$work/config" HELM_CACHE_HOME="$work/cache" HELM_DATA_HOME="$work/data"

info "installing Argo CD (pinned chart from $INSTALL_DIR)"
run helm repo add argo https://argoproj.github.io/argo-helm
run helm dependency build "$INSTALL_DIR"
run helm upgrade --install argocd "$INSTALL_DIR" \
  --namespace argocd --create-namespace \
  --kube-context "$CONTEXT" \
  --values "$INSTALL_DIR/values.yaml" \
  --wait --timeout 10m

info "waiting for Argo CD to be ready"
run kubectl --context "$CONTEXT" -n argocd rollout status deployment/argocd-server --timeout=300s
run kubectl --context "$CONTEXT" -n argocd rollout status deployment/argocd-repo-server --timeout=300s
run kubectl --context "$CONTEXT" -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
run kubectl --context "$CONTEXT" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# --- register the in-cluster secret with labels and annotations ---

bool_word() { if [ "$1" -eq 1 ]; then echo true; else echo false; fi; }

# The labels select which add-ons a cluster gets; the annotations carry identifiers that the
# ApplicationSets turn into Helm parameters. None of it is stored in Git.
build_cluster_secret() {
  jq -n \
    --arg external_dns "$(bool_word "$ENABLE_EXTERNAL_DNS")" \
    --arg dns01 "$(bool_word "$ENABLE_DNS01")" \
    --arg cluster_name "$CLUSTER_NAME" \
    --arg region "$REGION" \
    --arg account_id "$ACCOUNT_ID" \
    --arg vpc_id "$VPC_ID" \
    --arg lbc_role "$LBC_ROLE_ARN" \
    --arg extdns_role "$EXTERNAL_DNS_ROLE_ARN" \
    --arg certmgr_role "$CERT_MANAGER_ROLE_ARN" \
    --arg zone "$HOSTED_ZONE_ID" \
    --arg domain "$DNS_DOMAIN" \
    --arg email "$ACME_EMAIL" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        name: "cluster-in-cluster",
        namespace: "argocd",
        labels: {
          "argocd.argoproj.io/secret-type": "cluster",
          "platform.example/managed": "true",
          "platform.example/cloud": "aws",
          "platform.example/external-dns": $external_dns,
          "platform.example/dns01": $dns01
        },
        annotations: {
          "platform.example/cluster-name": $cluster_name,
          "platform.example/region": $region,
          "platform.example/account-id": $account_id,
          "platform.example/vpc-id": $vpc_id,
          "platform.example/lbc-role-arn": $lbc_role,
          "platform.example/external-dns-role-arn": $extdns_role,
          "platform.example/cert-manager-role-arn": $certmgr_role,
          "platform.example/hosted-zone-id": $zone,
          "platform.example/dns-domain": $domain,
          "platform.example/acme-email": $email
        }
      },
      type: "Opaque",
      stringData: {
        name: "in-cluster",
        server: "https://kubernetes.default.svc",
        config: "{\"tlsClientConfig\":{\"insecure\":false}}"
      }
    }'
}

info "registering the in-cluster secret (labels and annotations only; no credentials)"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '[dry-run] kubectl --context %s apply -f - <<< (Secret cluster-in-cluster, built with jq):\n' "$CONTEXT"
  if command -v jq > /dev/null 2>&1; then
    build_cluster_secret
  else
    echo "(jq is not installed, so the manifest is not shown)"
  fi
else
  build_cluster_secret | kubectl --context "$CONTEXT" apply -f -
fi

# --- projects and the root Application ---

info "applying the AppProjects and the root Application from $BOOTSTRAP_DIR"
warn "the root Application reads Git, not this working tree: the platform/argocd/apps changes must be on 'main' in GitHub"
run kubectl --context "$CONTEXT" apply -f "$BOOTSTRAP_DIR"

# --- access instructions ---

cat << EOF

Argo CD is installed. It has no ingress; reach it through a port-forward:

  kubectl --context $CONTEXT -n argocd port-forward svc/argocd-server 8080:80

Then open http://localhost:8080 and sign in as "admin".

Initial admin password (printed only when you run this yourself):

  kubectl --context $CONTEXT -n argocd get secret argocd-initial-admin-secret \\
    -o jsonpath='{.data.password}' | base64 -d; echo

Rotate it right after the first login, then delete the initial secret:

  argocd login localhost:8080 --username admin --plaintext
  argocd account update-password
  kubectl --context $CONTEXT -n argocd delete secret argocd-initial-admin-secret

Watch the add-ons sync:

  kubectl --context $CONTEXT -n argocd get applications

EOF
