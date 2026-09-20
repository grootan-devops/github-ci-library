# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## Unreleased

Seven changes require consumer action.

### Status check names changed

Every job name dropped the category prefix its caller already supplied, so branch
protection pinned to an old name must be repointed.

| Workflow | Old | New |
|---|---|---|
| `check.yml` | `Check: Verdict` | `Verdict` |
| `check.yml` | `Check: Git Tag` | `Git Tag Unused` |
| `check.yml` | `Check: Image Not Published` | `Image Tag Unused` |
| `check.yml` | `Check: Chart Not Published` | `Chart Version Unused` |
| `docker.yml` | `Image: Build & Push` / `Image: Smoke Test` / `Image: Promote` | `Build & Push` / `Smoke Test` / `Promote` |
| `chart.yml` | `Chart: Lint` / `Chart: Package` / `Chart: Push` | `Lint` / `Package` / `Push` |
| `scan.yml` | `Scan: <type>` | `<type>` |
| `sbom.yml` | `SBOM: Generate` / `SBOM: Scan` | `Generate` / `Scan` |
| `release.yml` | `Release: Publish` / `Release: Notify Teams` | `Publish` / `Notify Teams` |
| `secret-scanning.yml` | `Security: Secret Scan` | `Secret Scan` |
| `sonarqube.yml` | `Quality: SonarQube` | `SonarQube` |
| `trivy-cache.yml` | `Trivy: Warm Cache` | `Warm Cache` |
| `*-build.yml` | `<Lang>: Build` / `<Lang>: Unit Test` | `Build` / `Unit Test` |
| `terraform-*.yml` | `Terraform: <name>` | `<name>` |

Job **IDs** did not change, so `needs:` and `needs.<id>.outputs` are unaffected.

### Promotion refuses an unscanned image

`docker.yml` and `buildah.yml` gained `require-scan` (default `true`) and `scan-result`.
A release caller must pass the scan job's result:

```yaml
      scan-result: ${{ needs.scan.result }}
```

Without it the promote job fails, naming the fix. Set `require-scan: false` for an
artifact with no scan in its pipeline.

### `docker.yml` no longer takes `lint`

The Dockerfile lint moved to `lint.yml`, which already discovers a Dockerfile. A caller
passing `lint:` to `docker.yml` now gets an unknown-input error; call `lint.yml` alongside
the image build instead. It was removed because a caller depends on the whole workflow, so
a lint job inside it put the scan and the release guards behind hadolint.

### `trivy-cache.yml` requires `actions: write`

The warm job now declares it, rather than inheriting whatever the caller granted. A reusable
workflow cannot request a permission its caller did not grant, so a caller that stops at
`actions: read` fails at startup. Grant `actions: write` wherever `trivy-cache.yml` is called.

### Only `TOOLKIT_BUILD_IMAGE` is injected as a build arg

`docker.yml` previously emitted four build args — `JAVA25_BUILD_IMAGE`, `GO_BUILD_IMAGE`,
`TOOLKIT_BUILD_IMAGE` and `BUILDAH_BUILD_IMAGE` — all hard-coded to the same fixed toolkit
tag. There is no per-language build image: Go, JDK + Maven, Python, Node and buildah are all
baked into the toolkit. The three per-language args are gone, and `TOOLKIT_BUILD_IMAGE` now
resolves from `vars.TOOLKIT_BUILD_IMAGE`, prefixed with `vars.IMAGE_REGISTRY` like the base
images beside it. This matches what GitLab already passed.

Set `TOOLKIT_BUILD_IMAGE` at organisation level; a repository that leaves it unset gets a
pull failure naming the empty reference, which is the intended failure rather than a
silently wrong image version.

A Dockerfile that declares `ARG GO_BUILD_IMAGE`, `ARG JAVA25_BUILD_IMAGE` or
`ARG BUILDAH_BUILD_IMAGE` must switch to `ARG TOOLKIT_BUILD_IMAGE` — those three now resolve
empty. Only a multi-stage Dockerfile with a builder stage is affected.

### `mono.yml` removed

GitHub monorepo support is withdrawn. `mono.yml` and `vars.MONO_PROJECTS` are gone, and a
caller that references either now fails to resolve the workflow.

There is no replacement. GitHub cannot call a reusable workflow from a matrix, so the
workflow only ever returned a changed-project matrix for the caller to fan out over itself
— a thin wrapper around `git diff` that every caller had to re-implement around anyway.
A repository with several deployables gets one workflow file per deployable instead.

`project-path` is unaffected and still resolves a project that does not sit at the
repository root. The GitLab library keeps its parent/child monorepo pipelines.

### Caches are written only from the default branch

GitHub scopes every cache entry to the ref that wrote it. A run may read its own ref, its
base branch and the default branch — nothing else. Writing from every ref therefore produced
one full copy per branch and per pull request that no other ref could use: five 920 MB
`trivy-db` entries against a 10 GB repository limit, evicting each other.

Every `actions/cache/save` in the library now runs only when
`github.ref_name == github.event.repository.default_branch`. Restores are unchanged, so a
branch or PR still reads the default branch's entry. The cache-refresh steps in
`trivy-cache.yml` and `sonarqube.yml` are gated the same way — they *delete* the shared
entry before rewriting it, which a pull request must never do.

Consumer action: none required, but the first default-branch run after upgrading is what
populates the shared entry. Until it happens, branches and PRs run against a cold cache.
Delete the stale per-ref entries under **Actions → Caches** to reclaim the space.

`trivy-cache.yml` additionally now downloads the **vulnerability** database, not just the
checks bundle and `trivy-java-db`. It never warmed `db/`, so every image and SBOM scan
restored the cache and then downloaded the database anyway.

## 1.0.0

No migration is required for the initial release.
