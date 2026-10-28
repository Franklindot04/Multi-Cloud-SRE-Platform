# ADR-0017: CI pipeline and image publishing

- Status: Accepted
- Date: 2026-10-27

## Context

The four sample services have Dockerfiles, tests, an integration suite ([ADR-0015](0015-service-data-integration.md)) and a Helm chart that reads its image registry, tag and digests from one values file ([ADR-0016](0016-service-deployment-model.md)). Nothing built or tested the applications in CI, and no image was published, so a cluster that enables the services could not start them. This change adds the pipeline that tests the services, builds their images and publishes them to GitHub Container Registry (GHCR). It does not deploy anything and does not change `deploy/helm/values/images.yaml`.

## Decision

Path-filtered, per-service jobs

- `apps.yml` lints and tests each service in its own matrix job, with the toolchain and dependency cache that service needs (Go modules, uv and the hash-pinned requirements, the Maven repository). A small script, `scripts/changed-services.sh`, turns the list of changed files into the set of affected services: a change under `apps/<service>/` affects that service; a change to a shared script, the compose files, the Makefile or the workflow itself affects all of them.
- The filter is a script with tests, not an action, so the rule is readable, runs the same on a laptop, and adds no third-party code to a job that sees the repository. A workflow-level `paths:` filter keeps the workflow off unrelated pull requests, and the change detection narrows it further per service. A final `result` job gives branch protection one stable check name that treats skipped jobs as success.
- Each service has lint and unit tests on its own, so a Java-only change does not pay for the Go and Python toolchains, and a failure names the service. The integration suite and the smoke tests run once for the whole stack (they need all four services and the data layer) whenever anything under `apps/` changes, because an integration fault is usually a contract between services.
- The integration job reuses the existing entry points (`make integration-test`, which includes `smoke-test.sh --integration` and the chaos checks, and `make smoke-test-stack` for the in-memory stack) against real PostgreSQL, Valkey and RabbitMQ containers on the runner. The stack always tears down, and on failure the container logs are uploaded as an artifact (`INTEGRATION_LOG_DIR`).
- Concurrency groups cancel a superseded run on a pull request and never cancel a run on `main`.

Pull requests build, they never push

- `images.yml` builds each changed image for `linux/amd64` with Docker Buildx and the GitHub Actions cache on pull requests, without a registry login and with the default read-only token. A broken Dockerfile is found in review, and the cache makes the publish build after the merge fast. Pushing from a pull request would mean a registry credential reachable from code under review, and images of unmerged code in the registry.
- The publish job runs only on `push` to `main`, has `packages: write` and nothing broader, and never runs for a pull request, so a pull request from a fork cannot reach it. It logs in with the workflow's built-in token; no other secret exists.

SHA tags, no `latest`

- Each image is tagged with the full commit SHA and a short SHA. The full SHA is never reused, so a tag identifies exactly one build; the short SHA is a convenience for humans. There is no `latest` tag: it moves, hides what runs in a cluster, and makes a rollback ambiguous. The Helm values carry the tag and a digest, and the digest is what a node pulls.
- Only changed services are built, so a commit's SHA tag exists only for those. That is why the chart pins by digest too: an unchanged service keeps its previous digest, and the helper script keeps existing digests when it writes new ones.
- Images carry OCI labels: source, revision, created, version (the full SHA), licenses (MIT), title, description and url. The Go images also get `VERSION` and `COMMIT` build arguments, as their Dockerfiles define. The owner name is lower-cased in the workflow from `github.repository_owner`; nothing is hard-coded.
- Buildx provenance and SBOM attestations are switched off for now, so each tag is a single manifest with one plain digest.

CI does not commit image tags back

- CI never pushes commits, branches or tags and never opens pull requests. A bot that writes to `main` needs a credential with write access to the repository (a token or an app) that can bypass review, and a loop guard so its commit does not trigger itself. The values file is also the deployment decision: what runs in the clusters should change only through a reviewed commit.
- Instead the publish run writes a job summary with the registry, tag and digest of each pushed image and the exact `scripts/update-image-values.sh` command. A person runs it, which edits only the tag line and the `digests` entries (keeping comments and the registry), and opens a normal pull request. The helper is validated and idempotent, prints a diff, has a `--dry-run`, and runs no version control commands. Automating the pull request (for example with a reviewed GitHub App) is possible later without changing anything else.

Permissions and fork safety

- Default permissions are `contents: read` in every workflow. `packages: write` appears on one job only. There is no `pull_request_target`, no `workflow_run` chain that would run untrusted code with a privileged token, and no secret beyond the built-in token.
- No untrusted value (branch names, pull request titles, commit messages, file names) is interpolated into a shell command: values reach scripts through `env:` and are quoted. No `${{ }}` expression appears inside a `run:` script, and matrix values are produced by our own script from a fixed set of service names. Checkouts do not persist credentials.
- Third-party actions are pinned to full commit SHAs that were resolved from the release tags and checked when the workflow was written (the release is named in a comment). The tools that are downloaded rather than used as actions (shellcheck) are verified by checksum, as in the other workflows. The older workflows still use version tags; moving them to SHAs belongs to the supply chain change.

Caching

- Go modules, uv and Maven caches are handled by the setup actions and keyed on `go.sum`, the requirements files and `pom.xml`. Image layers use the GitHub Actions cache (`type=gha`, `mode=max`) scoped per service. Pull request caches are not shared with other pull requests, so one cannot poison another; `main` populates the cache the next build reads.

`linux/amd64` only for now

- The clusters run amd64 nodes (two Spot nodes), so one platform is built, natively on the amd64 runner, which is the fast path. Adding arm64 later (Graviton or Tau T2A nodes) means adding `linux/arm64` to `platforms`, which builds under QEMU emulation (slow, especially for the JVM and Python dependency steps) or on a native arm64 runner with a manifest list merging the two. The digest in the values file would then point at the multi-platform index. The services have no architecture-specific code.

Deferred to the supply chain change

- SBOM generation, vulnerability scanning with a gate, keyless signing and verification, build provenance attestations, pinning the existing workflows' actions to SHAs, and pinning the base images in the Dockerfiles to digests with an automated update. The publish job has commented placeholders where the first three go. Also deferred: multi-architecture images, retention of old tags, an automated pull request for the values file, and promotion between environments.

## Consequences

- Reviewers see a failing lint, test, integration or image build before merge, per service. A Dockerfile mistake no longer reaches `main`.
- A release is two steps with a human in between: merge (CI publishes), then a pull request with the new tag and digests. The cost is a short delay and a manual command; the benefit is that CI holds no write access to the repository and every deployed version is a reviewed commit.
- The integration job is the slowest part of a run (it builds the images and starts the data layer); it runs once per run, not per service.
- Until the supply chain change, the published images are unsigned and unscanned.

## Alternatives considered

- One reusable workflow per service: clearer separation, but four near-identical files to keep in step; a matrix over a computed list gives the same isolation with one definition.
- A third-party paths-filter action: less code, more trusted third-party code in jobs that read the repository.
- Pushing on pull requests to a staging tag: faster previews, but a registry credential reachable from code under review.
- Committing the new tag from CI: removes the manual step, adds a privileged write path and bypasses review.
- A `latest` tag, or moving tags per branch: convenient and ambiguous; digests and SHA tags answer "what is running".
