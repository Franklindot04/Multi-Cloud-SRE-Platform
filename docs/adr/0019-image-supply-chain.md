# ADR-0019: Image supply chain

- Status: Accepted
- Date: 2026-10-30

## Context

[ADR-0017](0017-ci-pipeline-and-image-publishing.md) builds and publishes the four service images (gateway, orders, payments, notifier) to GitHub Container Registry and deferred the rest of the supply chain: until now the published images were unscanned and unsigned, and nothing said what they contain or how they were built. The values file pins every service by digest, so the digest is the identity that matters: whatever is said about an image has to be said about its digest.

The questions this change answers are: does the image contain a known, fixable vulnerability (before merge and after publish), can a consumer check that a digest was produced by this repository's workflow on `main` and not by someone else, what is in the image, and how was it built. It keeps the constraints of ADR-0017: no secrets and no long-lived keys, CI never commits, a pull request from a fork can never reach a privileged job, and every action is pinned to a commit SHA.

## Decision

Scan every pull request that changes an image

- The `build` job of `images.yml` (one matrix job per changed service) builds the image into the local Docker daemon with `load: true`, pushes nothing, and scans it with Trivy. The job fails on `HIGH` or `CRITICAL` vulnerabilities that have a fixed version (`--ignore-unfixed`). The scan covers operating system packages and language dependencies; it does not look for secrets or misconfigurations.
- "Changed" is the existing rule: a change under `apps/<service>/` builds and scans that service, and a change to the workflow or to `.trivyignore` builds and scans all four.
- Accepted findings live in `.trivyignore`, in the plain Trivy format. Every entry has a reason on the line above it (`# reason: ...`, at least ten characters) and an expiry date (`exp:YYYY-MM-DD`). `scripts/check-trivyignore.sh` runs before the scan, in both the pull request job and the publish job, and fails the job for an entry without a reason, without a valid date, or whose date has passed. The check exists because Trivy does not require a reason at all and silently stops honouring an expired entry; the script turns both into a clear failure with the entry named. The file has no entries today.
- The workflow gets an `Images result` job that passes when every job it depends on succeeded or was skipped and fails on a failure or cancellation, the same rule as `Apps result` in `apps.yml`. `Apps result` itself is unchanged: the scan lives in the images workflow, next to the build it needs, rather than building each image a second time in the apps workflow. Because the images workflow only starts for changes under `apps/`, to the workflow or to `.trivyignore`, a pull request that touches none of them has no `Images result` check; that was already true of the build job and is why `Images result` is not a good candidate for a required check on every pull request.

Publish: everything refers to the pushed digest

After the existing build and push on `main`, the publish job, still one matrix job per changed service, does the following with `ghcr.io/<owner>/<service>@sha256:<digest>`. No step uses a tag.

1. **SBOM.** Trivy writes an SPDX 2.3 JSON SBOM for the pushed digest. It is kept as a workflow artifact (`sbom-<service>`, 90 days).
2. **Scan.** The same gate as on a pull request, against the pushed digest.
3. **Sign.** `cosign sign` signs the digest keylessly. The certificate is issued by Sigstore to the workflow's GitHub OIDC identity and the signature is recorded in the public Sigstore transparency log. There is no key to store or rotate.
4. **SBOM attestation.** `cosign attest --type spdxjson` attaches the SBOM to the digest as a signed in-toto attestation.
5. **Provenance.** `actions/attest-build-provenance` publishes SLSA build provenance for the digest and pushes it to the registry next to the image.
6. **Verify.** `scripts/verify-image.sh <service> <digest>` runs the checks described below on what was just published.

Only then does the job upload the digest that the `Publish summary` job lists. The order makes the job fail closed: if the scan, signing, an attestation or the verification fails, the digest is never handed on, so the release command in the summary never offers it. The image itself is already in the registry by then, tagged and unsigned. That is a known limit of scanning after the push (the build must push to produce a digest to sign), and the runbook says not to use such an image.

Verification

- `scripts/verify-image.sh` takes a service (or `all`) and an optional digest, defaulting to the one in `deploy/helm/values/images.yaml`. For each image it runs `cosign verify` and `cosign verify-attestation` for `spdxjson` and for `slsaprovenance1`, prints PASS or FAIL for each and for the image, and exits non-zero if anything failed.
- The expected signer is pinned exactly, not by pattern: the certificate identity `https://github.com/Franklindot04/Multi-Cloud-SRE-Platform/.github/workflows/images.yml@refs/heads/main` and the issuer `https://token.actions.githubusercontent.com`. A signature from another workflow, another branch (including a pull request build), another repository or a person's own Sigstore identity fails. A fork can set `SIGNER_REPOSITORY` and `IMAGE_REGISTRY` to verify its own images.

Least privilege and pinning

- Workflow-level permissions stay `contents: read`. Only the publish job adds `packages: write` (push the image and the provenance bundle), `id-token: write` (the OIDC token that keyless signing and the provenance attestation use) and `attestations: write` (store the provenance). The provenance action's storage record is switched off because it would need one more permission (`artifact-metadata: write`) that nothing here uses. The pull request job keeps the default read-only token and does no registry login.
- There is no `pull_request_target`, no new secret and no key. Untrusted values still reach scripts only through `env:`.
- Actions are pinned to full commit SHAs resolved from the release tags on 2026-10-30 (the release is named in a comment): `sigstore/cosign-installer` v4.1.2 and `actions/attest-build-provenance` v4.2.2, next to the pins already in the workflow. The runner stays `ubuntu-24.04`.
- Trivy is not used through its action. The Trivy actions had tags rewritten to malicious code in March 2026, and the safe versions rely on the project's recovery. The workflow instead downloads the Trivy 0.76.1 release archive and checks it against a SHA-256 stored in the workflow, the way `shellcheck` is installed in `apps.yml`. The hash was taken from the release's checksums file over HTTPS (that release is marked immutable); the checksums file's Sigstore bundle was not checked. Trivy and cosign are therefore the two pieces of third-party code that run with the publish job's permissions, together with the pinned actions.
- cosign comes from the installer action, which checks the binary against a hash that ships inside the action. The installed version is the installer's default for that release (v3.0.6), not the newest cosign.

CI still never commits. `scripts/update-image-values.sh` and the pull request based release flow are unchanged; the values file stays the deployment decision.

## Consequences

- A fixable HIGH or CRITICAL vulnerability in an image fails the pull request that introduces it (or the one that touches the image after the vulnerability was published), and the finding names the package, the installed version and the fixed version. The base images of Go, Java and Python move with security updates, so a pull request can start failing without a code change; the fix is a rebuild, a dependency bump or a short, justified `.trivyignore` entry.
- Every image pushed from `main` has an SBOM, a signature and provenance that anyone can check with one command and a pinned identity. The first publish after this change is the first time any of it runs on GitHub (see below).
- The publish job is longer and holds more permissions than before. The extra permissions are the ones the OIDC and attestation steps need, they sit on one job that fork pull requests cannot reach, and nothing else in the workflow can use them.
- `scripts/verify-image.sh` fails for the digests currently in `deploy/helm/values/images.yaml`: they were published before this change and carry no signature or attestation. That is expected until a release made after this change is rolled in.
- The signing certificate, the repository name and the image digest appear in the public Sigstore transparency log, even for a private package.
- Scanning needs the Trivy vulnerability database from `ghcr.io/aquasecurity` when the job runs, so an outage there fails the scan job (a re-run is the remedy; do not add an ignore entry for it).

## What this does not cover

- **Already published images are not rescanned.** A vulnerability published after an image was pushed is not noticed until the image is rebuilt. A scheduled rescan of the digests in the values file is the obvious next step.
- **Unfixed vulnerabilities are not reported.** `--ignore-unfixed` means a HIGH or CRITICAL finding without a fixed version passes. Trivy also only knows what its database knows, and it can miss or misreport.
- **A signature is not a review.** It says this digest was produced by the images workflow on `main` of this repository, which can only be changed through reviewed commits. It does not say the code is safe, or that the workflow could not be changed by someone with the right to merge.
- **The provenance is the build platform's own statement.** GitHub's runner produces it with no separate builder isolation. No SLSA level is claimed.
- **Nothing in the clusters checks any of this.** An admission policy that refuses unsigned or unverified images belongs to the security phase. Until then verification is a CI step and a command people run.
- **Base images are not pinned to digests.** The Dockerfiles still use version tags, and the distroless tags move, so two builds of the same commit can differ. The SBOM and scan describe the build that was pushed. Pinning with automated updates is still open, as are multi-architecture images and a retention policy for old tags and attestations.
- **Dependencies are only as trusted as their sources.** The scan looks for known vulnerabilities, not for a malicious package.
- **The older workflows** keep their own pins; this change does not touch them.

## What has been exercised

Checked before this change was merged, on a laptop: the workflow with `actionlint`; the new scripts with `shellcheck` at the strictest level; `scripts/check-trivyignore.sh` and `scripts/verify-image.sh` against a fake `cosign` (argument handling, output, the exact identity and issuer in every call, a failure of each check, an image signed by another branch, repository or issuer, and one bad image among four); and Trivy 0.76.1 itself, downloaded and checked against the SHA-256 in the workflow, with the exact flags of the scan step against a local image (clean image, a failing gate, an ignore file with active entries, and the same entries expired) and the SPDX output.

Not exercised, because it needs the real GitHub runner and a real push to `main`:

- the whole publish path: the registry login being enough for Trivy to read the pushed digest, `cosign sign` and `cosign attest` with the runner's OIDC token, the size and acceptance of the SBOM attestation, and the provenance action pushing its bundle with the permissions given;
- that `cosign verify-attestation --type slsaprovenance1` finds the provenance bundle the attestation action pushed. This is the least certain step: the verification and the provenance action are separate tools, and if cosign does not discover that bundle, the `Verify` step fails the first publish and the check has to change (for example to `gh attestation verify`) before anything can be released. That failure is safe, since nothing is handed on, but it is likely enough to expect;
- the pull request scan job as a GitHub job (the install step, `load: true` followed by `--image-src docker`, the cache), and the `Images result` job;
- `scripts/verify-image.sh` against real signatures; it has only run against the fake.

The first merge to `main` that changes an image is therefore the real test of the publish half.

## Alternatives considered

- **`aquasecurity/trivy-action`.** Convenient, but its tags were rewritten once and the recovery depends on the maintainers; a checksum-pinned binary needs no action. The cost is two lines to change on an upgrade.
- **Scan only on publish, or only on pull requests.** Pull requests alone miss new vulnerabilities in the base image after merge; publish alone finds a problem after the image is already in the registry. Both give different information.
- **Failing on unfixed findings too.** It would block merges on problems nobody can fix. The decision to accept such a finding can be recorded the same way as any other, in `.trivyignore`, if it is ever wanted.
- **A key pair for signing.** A key needs storing, rotating and protecting from the job that uses it; keyless signing uses the identity the job already has.
- **`gh attestation verify` as the only verifier.** It works for GitHub attestations but does not cover the cosign signature and the SBOM attestation, and needs the GitHub CLI; one tool for all three checks is simpler to test and to run. It stays the fallback for provenance.
- **Syft or another SBOM tool.** A second tool for no gain; Trivy already reads the image and produces SPDX.
- **Scanning in `apps.yml` so `Apps result` covers it.** Would build every image a second time per pull request, or move the build there. Putting the scan beside the existing build and adding an `Images result` job keeps one build.
