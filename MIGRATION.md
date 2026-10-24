# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

To upgrade, apply every section after your pinned version up to the target, oldest first.
Newer sections are split into **Required** (the upgrade breaks or misbehaves without it),
**Recommended** (aligns an existing project with the current standards) and **Verify**.

## 1.7.0

### Required

No registry migration is required. A single `IMAGE_REGISTRY` or `CHART_REGISTRY` with the
existing secret pairs behaves as before, and everything new is optional. A caller that passes
`REGISTRY_CONFIG` explicitly to `deploy-argocd-gitops.yml` or `deploy-komodo-gitops.yml` must pin
`1.7.0` or later, because earlier releases reject it as an unknown secret.

- **`vars.PROJECT_REGISTRY_NAME` now selects a credential group.** `1.6.1` ignored it. An
  organisation or repository that sets it for anything else removes it: set together with
  `IMAGE_REGISTRY` or `CHART_REGISTRY`, it now stops the first step of `init.yml`.
- **Terraform status checks are renamed.** `Init (root)`, `Documentation (root)` and
  `Module Test (root)` report as `Init`, `Documentation` and `Module Test`. Update any branch
  protection rule or ruleset that requires the old names, or pull requests wait on a check that
  never reports.
- **Terraform jobs run wherever `terraform-lint.yml` or `terraform-test.yml` is called.** None
  checks for `main.tf` any more. Point `project-path` at the Terraform root, or stop calling them
  from a repository that has no Terraform.

### Recommended

- **Publishing to several registries**:
  - Add a credential group to the `REGISTRY_CONFIG` organisation secret, as YAML: a name such as `oneuptime/prod` mapping each registry host to its `username` and `password`, every value quoted.
  - In each repository that publishes to several registries, set `PROJECT_REGISTRY_NAME` to the group and list the full repositories in `IMAGE_REPOSITORY` and `CHART_REPOSITORY`, primary first, e.g. `registry.example.com/core/api quay.io/oneuptime/api`.
  - Stop `IMAGE_REGISTRY` and `CHART_REGISTRY` from reaching that repository: an organisation variable can be limited to the repositories that still use it.
  - See [Publishing to several registries](docs/configuration.md#publishing-to-several-registries).
- **Where to set `PROJECT_REGISTRY_NAME`.** Per repository as it moves to `1.7.0`, or at organisation level only once every repository pins `1.7.0` or later: earlier releases ignore it and would take a full repository for a path.
- **Docker Hub** images are written `docker.io/<namespace>/<name>` and charts `registry-1.docker.io/<namespace>`; a group's `docker.io` serves both.
- **Repositories that build with `buildah.yml`** keep `IMAGE_REGISTRY` and its secret pair: Buildah publishes internal images to that single registry and does not read `PROJECT_REGISTRY_NAME`.
- **Before the first push**, create the repository, or the Harbor project, in every registry.
- **Callers that pass secrets explicitly** instead of `secrets: inherit`: add `REGISTRY_CONFIG` to the deploy workflow calls.

### Verify

- A repository that sets both `PROJECT_REGISTRY_NAME` and `IMAGE_REGISTRY` fails the first
  step of `init.yml`, and no other job runs.
- The `🚀 Version & Targets` summary lists every repository.
- After a release, every repository holds the release tag and its `latest`, major and minor tags,
  all at the same digest (`crane digest`).
- On a self-hosted runner, `~/.docker/config.json` gains no entries from the build and smoke-test
  jobs.
- `Validate` and `TFLint` pass on a pull request that adds a module, and in a repository whose
  default branch has never saved a Terraform provider cache.

## 1.6.1

No migration is required. This release only updates dependencies.

## 1.6.0

### Required

No migration required. `buildah.yml` gains optional `test`, `test-script`, `test-path` and
`test-shell` inputs that default to off; existing callers behave as before. A `buildah.yml`
caller that passes any of these inputs must pin `1.6.0` or later, because earlier releases reject
them as unknown inputs.

### Recommended

- Smoke-test Buildah images the same way as Docker images: set `test: true` on the `buildah.yml`
  caller and commit a `ci_image_test.sh` (or point `test-script`/`test-path` at an existing one).
- A minimal Buildah image usually has no `bash`. Set `test-shell` to an interpreter the image
  actually contains, e.g. `sh`, or the test fails before the script runs.

### Verify

- The pull request pipeline passes with the new pin.
- With `test: true`, the run summary shows the `🧪 Image smoke test` section for the Buildah
  image, run against its `image-ref-digest`.

## 1.5.0

### Required

No migration required. The reusable workflow inputs, outputs and behaviour are unchanged; this
release documents the standards the workflows already assume.

### Recommended

Align an existing project with the documented standards:

- PID 1 is `ENTRYPOINT ["/usr/bin/dumb-init", "--"]`, with the process, or a start script that
  ends in `exec`, in `CMD`.
- Base images come from the injected build-arg `ARG`s. A `# renovate:` annotation goes only on a
  public-registry image version held in an `ARG`, and no secret is passed as an `ARG`.
- Paths the application writes at runtime, and a single-page application's runtime
  configuration, are chart mounts rather than files built into the image.
- The repository keeps only the scenario files its shape needs. A workflow that can also be
  called (`workflow_call`) declares no `concurrency:` group, and release and deploy callers keep
  `cancel-in-progress: false`.

### Verify

- The pull request pipeline passes with the new pin.

## 1.4.0

No consumer workflow migration is required. Docker image builds no longer push or pull remote registry `buildcache` layers by default, and `RELEASE_MIGRATION.md` is consolidated directly into the GitHub Release body notes rather than published as a standalone downloadable asset. Container base and builder images have been upgraded to their latest stable releases (`micro-root:1.1.0`, `micro-nginx:1.1.1`, `micro-python-3-12:1.1.1`, `micro-java-25:1.1.1`, `micro-node-24:1.1.1`, `toolkit:1.1.0`).

## 1.3.0

No migration is required. The reusable workflow inputs remain backward-compatible.

## 1.2.0

The documentation restructuring requires no consumer configuration changes. Start at the
README index and follow its task-specific links; update bookmarks to moved sections.

The chart workflow's default mock consumer chart directory is now `tests` instead of
`test`. Rename the fixture directory to `tests/`, or keep the old location temporarily by
setting `mock-chart: test`. Mock chart suites are selected from each chart's own
`tests/*_test.yaml` files.

The Dockerfile guide now clarifies a cache limitation in the GitHub workflows: Python and Node
dependency caches are not automatically transferred from their language workflow jobs into the
separate `docker.yml` image-build job. Consumers whose Dockerfiles perform offline Python or
Node installs must explicitly provide the matching cache directory in the Docker build context;
the image workflow's registry-backed BuildKit cache is not a substitute. The examples use
read-write bind mounts because package managers may update cache metadata. This documentation
correction does not change workflow behavior; verify the cache handoff before relying on these
offline-install examples.

Publishing remains OCI-only and requires the chart registry, repository and credential pair.
Optional `CHART_DEPENDENCY_REGISTRY` and its username/password pair authenticate private
dependencies on a different host. Chart scans no longer use image credentials for dependencies.
If a standalone chart scan previously relied on image credentials, configure the chart
credential pair or the separate dependency-registry pair instead.
Registry errors now stop collision checks and promotion; only confirmed missing candidates
permit the existing warned working-tree fallback.

## 1.1.0

No migration is required. Consumers should pin reusable workflow references to
the stable `1.0.0` tag.

## 1.0.0

No migration is required for the initial release.
