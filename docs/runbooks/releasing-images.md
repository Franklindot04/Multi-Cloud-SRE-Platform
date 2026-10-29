# Releasing images

How a change to a sample service becomes a published image and then a deployed version. The reasoning is in [ADR-0017](../adr/0017-ci-pipeline-and-image-publishing.md); the chart and its values are described in [ADR-0016](../adr/0016-service-deployment-model.md) and the [service deployment runbook](service-deployment.md).

CI publishes images but never changes the repository. Rolling a new build out to a cluster is a normal pull request that edits [`deploy/helm/values/images.yaml`](../../deploy/helm/values/images.yaml).

## Release, end to end

1. **Merge** the change to `main`. The `apps` workflow ran on the pull request (lint, unit tests, integration and smoke tests), and the `images` workflow built the changed images without pushing.
2. **Wait for the publish jobs.** The `images` workflow on `main` builds each changed service for `linux/amd64` and pushes it to `ghcr.io/<lower-case owner>/<service>` tagged with the full commit SHA and a short SHA. Watch the run under Actions, workflow `images`.
3. **Read the job summary** of that run (the `Publish summary` job). It lists the registry, tag and digest of each image that was built, and the command to run. A digest appears there only after the publish job scanned it, signed it, attached the SBOM and the provenance, and verified all of that; if a publish job failed in one of those steps, its digest is missing on purpose and must not be deployed. To check a digest yourself, see [verify an image](service-deployment.md#verify-an-image).
4. **Run the helper script** from the repository root with the values from the summary. Look at the diff first:

   ```bash
   ./scripts/update-image-values.sh --dry-run --tag <full commit SHA> \
     --digest gateway=sha256:<digest> --digest orders=sha256:<digest>
   ./scripts/update-image-values.sh --tag <full commit SHA> \
     --digest gateway=sha256:<digest> --digest orders=sha256:<digest>
   ```

   It changes only the `tag:` line and the `digests:` entries, keeps the registry and the comments, keeps the digests of services you do not mention, and is safe to run twice.
5. **Open a pull request** with the change to `images.yaml`. The `deploy` workflow renders the chart under every profile and cloud. After review and merge, Argo CD syncs the clusters that have the services enabled (`platform.example/apps=true`).
6. **Verify** with the commands in the [service deployment runbook](service-deployment.md#verify): pods Ready, a request through the gateway, an order created and read back.

A commit that touches only some services publishes only those images, so the SHA tag exists only for them. That is expected: the chart pins every service by digest, and the helper keeps the digests of the services that were not rebuilt. Keep all four digests present once they exist.

The first release builds all four services, because the first run of the workflow (or any change to the workflow file) rebuilds everything.

## Package visibility

The first publish creates each GHCR package **private**, even in a public repository. Decide once per package (`gateway`, `orders`, `payments`, `notifier`):

**Make it public** (simplest for a public sample project; the images contain no secrets):

1. On GitHub, open the repository owner's page, **Packages**, and the package.
2. **Package settings**, then **Danger Zone**, **Change visibility**, choose **Public**, and confirm. This is one-time per package; a later publish keeps it.
3. The package is already linked to the repository through the `org.opencontainers.image.source` label that the images carry.

**Keep it private.** Clusters then need an image pull secret in the `shop` namespace, created by hand and never committed:

```bash
kubectl --context <CTX> -n shop create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<github user> --docker-password=<token with read:packages>
```

Then set `imagePullSecrets: [{name: ghcr-pull}]` for each service in its values file (a reviewed change). Use a token that has only `read:packages`, and rotate it like any credential. External Secrets (planned) can manage this Secret later.

## Roll back to a previous version

Rolling back is rolling forward to an earlier tag: it goes through a pull request too.

1. Find the tag and digests of the version you want: the job summary of the `images` run that published it, or the earlier content of `images.yaml` in the repository history, or the digest lookup below.
2. Run the helper with that tag and **all four** digests (a rollback must reset every service that changed since):

   ```bash
   ./scripts/update-image-values.sh --tag <previous full SHA> \
     --digest gateway=sha256:<...> --digest orders=sha256:<...> \
     --digest payments=sha256:<...> --digest notifier=sha256:<...>
   ```

3. Open the pull request. For an urgent rollback, an Argo CD **Rollback** of the affected Application to its previous revision is faster (disable automated sync first, or self-heal puts the new version back); then make the Git change so it matches.

Database migrations are forward-only: the previous application version must work with the current schema. Schema changes follow expand-then-contract for that reason ([ADR-0015](../adr/0015-service-data-integration.md)).

## Find the digest of an existing tag

```bash
docker buildx imagetools inspect ghcr.io/<owner>/<service>:<tag> --format '{{json .Manifest.Digest}}'
# or, with the registry API and a token that can read the package:
docker manifest inspect ghcr.io/<owner>/<service>:<tag> >/dev/null && echo exists
```

On GitHub, the package page lists each tag with its digest. Confirm the labels and the user of an image you pulled:

```bash
docker image inspect ghcr.io/<owner>/<service>:<tag> --format '{{json .Config.Labels}} {{.Config.User}}'
```

`org.opencontainers.image.revision` is the commit the image was built from. Pulling a private package needs `docker login ghcr.io` with a token that has `read:packages`.

## Troubleshooting

- **The publish job is missing:** it runs only on pushes to `main` and only for services whose files changed. Re-run the workflow or push a change under `apps/<service>/`.
- **`denied: permission_denied` pushing a package:** the package already exists and is not linked to this repository. In the package settings, add the repository under **Manage Actions access** with write role, or delete the empty package.
- **Pods `ImagePullBackOff` on a cluster:** the tag in `images.yaml` is still the placeholder, the package is private without a pull secret, or the digest does not exist for the tag. `kubectl -n shop describe pod` shows the reference.
- **The helper rejects my arguments:** it names the problem (a tag with a space, a digest that is not `sha256:` plus 64 lower-case hex characters, an unknown service) and changes nothing.
