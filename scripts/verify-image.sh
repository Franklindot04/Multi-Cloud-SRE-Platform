#!/usr/bin/env bash
# Verifies a published service image: the signature, the SBOM attestation and the build provenance, all for one
# digest, and all pinned to the identity of this repository's images workflow on main.
#
#   scripts/verify-image.sh SERVICE [DIGEST]
#   scripts/verify-image.sh all
#
# SERVICE is gateway, orders, payments or notifier; "all" checks the four digests in the values file. DIGEST is
# sha256:<64 hex>; without it the digest in deploy/helm/values/images.yaml is used (the one a cluster would
# pull). The image checked is ghcr.io/franklindot04/<service>@<digest>: always a digest, never a tag.
#
# Three cosign checks run for each image, and all three must pass:
#   1. cosign verify              the signature on the digest
#   2. cosign verify-attestation  the signed SBOM (type spdxjson)
#   3. cosign verify-attestation  the signed SLSA build provenance (type slsaprovenance1)
# The signing certificate must name exactly
#   https://github.com/Franklindot04/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/main
# and be issued for the GitHub Actions OIDC issuer, https://token.actions.githubusercontent.com. A signature made
# by another workflow, another branch, another repository or a person does not pass.
#
# Prints PASS or FAIL for each check and for each image. Exit status: 0 every check of every image passed,
# 1 at least one check failed, 2 bad arguments, a missing digest or cosign not installed.
#
# A private GHCR package needs `docker login ghcr.io` first (a token with read:packages). The checks also
# contact the public Sigstore transparency log. Environment, for a fork that signs with its own workflow:
#   IMAGE_REGISTRY       registry and owner (default ghcr.io/franklindot04)
#   SIGNER_REPOSITORY    owner/name of the repository whose workflow signs (default
#                        Franklindot04/Multi-Cloud-SRE-Platform)
#   VALUES_FILE          values file for the default digest (default deploy/helm/values/images.yaml)
set -euo pipefail

SERVICES="gateway orders payments notifier"
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/franklindot04}"
REPOSITORY="${SIGNER_REPOSITORY:-Franklindot04/Multi-Cloud-SRE-Platform}"
VALUES="${VALUES_FILE:-deploy/helm/values/images.yaml}"
ISSUER="https://token.actions.githubusercontent.com"
IDENTITY="https://github.com/${REPOSITORY}/.github/workflows/images.yml@refs/heads/main"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

SERVICE=""
DIGEST=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      if [ -z "$SERVICE" ]; then
        SERVICE="$1"
      elif [ -z "$DIGEST" ]; then
        DIGEST="$1"
      else
        die "too many arguments"
      fi
      shift
      ;;
  esac
done

[ -n "$SERVICE" ] || {
  usage >&2
  die "a service name is required (gateway, orders, payments, notifier or all)"
}
if [ "$SERVICE" != "all" ]; then
  case " $SERVICES " in
    *" $SERVICE "*) ;;
    *) die "unknown service '$SERVICE' (gateway, orders, payments, notifier or all)" ;;
  esac
fi
[ "$SERVICE" != "all" ] || [ -z "$DIGEST" ] || die "a digest cannot be combined with 'all'; every digest comes from $VALUES"
if [ -n "$DIGEST" ] && ! printf '%s' "$DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
  die "the digest must be sha256: followed by 64 lower-case hex characters (a tag is not accepted)"
fi
command -v cosign > /dev/null 2>&1 || die "cosign is not installed (https://docs.sigstore.dev/cosign/system_config/installation/)"

# digest_in_values SERVICE: the digest the values file pins for SERVICE, or nothing.
digest_in_values() {
  [ -r "$VALUES" ] || return 0
  sed -n 's/^  '"$1"': "\(sha256:[0-9a-f]\{64\}\)"[[:space:]]*$/\1/p' "$VALUES" | head -n 1
}

failed=0
checked=0

# run_check LABEL COMMAND...: PASS or FAIL for one cosign call; the reason is the last lines it printed.
run_check() {
  local label="$1" out
  shift
  if out="$("$@" 2>&1 > /dev/null)"; then
    printf '  PASS  %s\n' "$label"
  else
    printf '  FAIL  %s\n' "$label"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/          /'
    return 1
  fi
}

verify_one() {
  local service="$1" digest="$2" ref ok=0
  ref="${REGISTRY}/${service}@${digest}"
  printf '%s\n  %s\n' "$service" "$ref"
  run_check "signature" cosign verify \
    --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" "$ref" || ok=1
  run_check "SBOM attestation (spdxjson)" cosign verify-attestation --type spdxjson \
    --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" "$ref" || ok=1
  run_check "build provenance (slsaprovenance1)" cosign verify-attestation --type slsaprovenance1 \
    --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" "$ref" || ok=1
  checked=$((checked + 1))
  if [ "$ok" -eq 0 ]; then
    printf 'PASS  %s\n\n' "$service"
  else
    printf 'FAIL  %s\n\n' "$service"
    failed=$((failed + 1))
  fi
}

if [ "$SERVICE" = "all" ]; then
  targets="$SERVICES"
else
  targets="$SERVICE"
fi

# Resolve every digest first, so a missing one stops the run before anything is reported as checked.
plan=""
for s in $targets; do
  d="$DIGEST"
  [ -n "$d" ] || d="$(digest_in_values "$s")"
  [ -n "$d" ] || die "no digest for $s in $VALUES; pass one as the second argument"
  plan="${plan}${s} ${d}
"
done

printf 'Expected signer: %s\nExpected issuer: %s\n\n' "$IDENTITY" "$ISSUER"
while read -r s d; do
  [ -n "$s" ] || continue
  verify_one "$s" "$d"
done << EOF
$plan
EOF

if [ "$failed" -gt 0 ]; then
  printf 'FAIL: %s of %s image(s) did not verify.\n' "$failed" "$checked"
  exit 1
fi
printf 'PASS: %s of %s image(s) verified.\n' "$checked" "$checked"
