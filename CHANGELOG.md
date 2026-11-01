# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.10.0] - 2026-11-01

### Added

- Publishing to several registries. `IMAGE_REPOSITORY` and `CHART_REPOSITORY` take one or more full refs (`host/path`), primary first, and the `REGISTRY_CONFIG` secret holds per-registry credentials and options (`dev`, the candidate suffix). Candidates and releases go to the primary as before, then are copied by digest to the other registries: a new `docker.yml` · `copy` job for candidates, and a copy step after `docker.yml` · `promote`, `chart.yml` · `push` and `chart.yml` · `promote`. See [Registries](docs/configuration.md#registries) and [the example](docs/examples/multi-registry.md).
- `DEPLOY_IMAGE_REPOSITORY` / `DEPLOY_CHART_REPOSITORY`, and the `deploy-image-repository` / `deploy-chart-repository` inputs of both deploy workflows, choose which destination deploys, deploy validation and image scans read. The default is the primary.
- With no registry configured, images and charts go to GitHub Container Registry (`ghcr.io/<owner>/<repo>`, charts under `/helm`) with `GITHUB_TOKEN`.
- `BASE_IMAGE_REGISTRY`: the registry serving the base and SonarQube scanner images. The default is `IMAGE_REGISTRY`, else `docker.io`.

### Changed

- Every registry job writes one Docker `config.json` with `scripts/registry/auth.sh`, and docker, buildx, crane, Trivy and helm read it. It replaces `docker/login-action`, `crane auth login`, `helm registry login` and the hand-written Trivy credentials. `buildah.yml` is unchanged: it publishes to one registry.
- `init.yml` checks that every destination resolves and has credentials, and names the host that lacks them. Its registry and repository outputs name the primary; with the existing single-registry variables they are unchanged.
- `check.yml`'s image tag and chart version guards look in every destination; the chart dependency guard rejects every destination's candidate path. The `image-repository` and `chart-repository` inputs are no longer read.
- The deploy workflows' `dev-repository-suffix` input defaults to the suffix configured for the deployed registry instead of `/dev`; a value still overrides it. `deploy-komodo-gitops.yml` no longer requires the `IMAGE_REGISTRY_USERNAME` / `_PASSWORD` secrets.

## [1.9.0] - 2026-11-01

### Changed

- Updated [`grootantech/toolkit`](https://github.com/grootan-devops/toolkit) from [`1.1.0` to `2.0.1`](https://github.com/grootan-devops/toolkit/compare/1.1.0...2.0.1), the build container of every job. Toolkit 2.0.0 moves Node.js from 24 to 26 and npm to 12.2, and updates Helm 4.3.1, Trivy 0.76.1, Terraform 1.17.0, OpenTofu 1.13.2, yq 4.54.1, Go 1.27.3, Maven 3.10.0, uv 0.13.5, golangci-lint 2.15.0 and Biome 2.6.3.
- Updated [`moby/buildkit`](https://github.com/moby/buildkit) from [`v0.29.0` to `v0.34.1`](https://github.com/moby/buildkit/releases/tag/v0.34.1), the BuildKit driver of `docker.yml`.
- Updated the `docker.yml` base images injected as build arguments:
  - `grootantech/micro-root` from `1.1.0` to `1.2.0`
  - `grootantech/micro-nginx` from `1.1.1` to `1.2.1`
  - `grootantech/micro-python-3-12` from `1.1.1` to `1.2.1`
  - `grootantech/micro-node-24` from `1.1.1` to `1.2.1`
  - `grootantech/micro-java-25` from `1.1.1` to `1.3.1`

## [1.7.0] - 2026-10-26

### Added

- `terraform.yml`: the Terraform checks and the module test in one workflow, replacing `terraform-lint.yml` and `terraform-test.yml`. `lint` (default `true`) runs init, validate, fmt, TFLint and the documentation check with `state-name`; `test: true` runs the module test and its teardown, from a workflow that does not cancel superseded runs.
- `docs/workflow-map.json`: the scenario workflow files each project shape needs, for audit tools to read at the release a project pins. `docs/maintainer-guide.md` says how to keep it in step with the examples.

### Changed

- The Terraform jobs no longer look for `main.tf`. Calling `terraform.yml` opts a repository in, as with every other workflow. The jobs no longer run as a one-entry matrix, so `Init (root)`, `Documentation (root)` and `Module Test (root)` report as `Init`, `Documentation` and `Module Test`, under the calling job.
- `terraform.yml`: the provider cache holds only `.terraform/providers`. Restoring it no longer replaces the checked-out `.terraform.lock.hcl` with the default branch's copy, or brings in its modules and backend settings.
- The README header no longer carries a hand-kept release number or a link to the ai-skills compatibility page: the tag is the release, and the maintainer guide states the versioning policy.
- `docs/maintainer-guide.md`: the release and versioning policy (public interface, semantic versioning, deprecations).

### Removed

- `terraform-lint.yml` and `terraform-test.yml`, replaced by `terraform.yml`, with their `discover` jobs ("Detect Terraform Root Module") and the warning for a missing `main.tf`.

### Fixed

- `terraform.yml` · `Validate`, `TFLint`: run `terraform init -backend=false` before checking, instead of relying on the provider cache that only a default-branch run saves. They failed with `Missing required provider` or `Module not installed` when that cache was missing, or had been saved before the root gained a module.
- `scan.yml`: an explicit `IMAGE_DEV_REPOSITORY_SUFFIX` containing `/` is normalised to `-` on Docker Hub, as `init.yml` already did.
- Documentation:
  - `docs/configuration.md` no longer claims the released digest is the scanned one.
  - `docs/modules/init-check.md` counts 29 outputs.
  - `docs/docker.md` no longer mentions the registry layer cache removed in 1.4.0.
  - `docs/examples/gitops.md`: the ArgoCD example passes the required `argocd-server` input. Copied as it was, the call failed at startup.

## [1.6.1] - 2026-10-23

### Changed

- Updated [`docker/build-push-action`](https://github.com/docker/build-push-action) from [`v6@53b7df9` to `v6@10e90e3`](https://github.com/docker/build-push-action/compare/53b7df96c91f9c12dcc8a07bcb9ccacbed38856a...10e90e3645eae34f1e60eeb005ba3a3d33f178e8)

## [1.6.0] - 2026-10-22

### Added

- `buildah.yml` · `test`: optional smoke test executed inside the built image, with the same `test`, `test-script`, `test-path` and `test-shell` inputs and defaults as `docker.yml`. Off by default.

### Changed

- `docs/modules/image.md` and `docs/examples/buildah.md`: document the Buildah smoke test and choosing a `test-shell` the minimal image provides.

## [1.5.0] - 2026-10-01

### Added

- `docs/docker.md`: micro base image limits, final-layer cleanup and `.dockerignore` rules.
- `docs/getting-started.md`: scenario files for the repository's shape (image-only repositories, `paths:` filters), workflow file layout and `.gitignore` entries.
- `docs/pipeline-lifecycle.md`: job responsibilities and the concurrency deadlock of a workflow that is both dispatched and called.
- `docs/security.md`: reviewing a consumer repository — secrets by value, pipeline posture and GitHub specifics.
- The per-stack project rules in the Node.js, Python, Go, Java and chart module guides.

### Changed

- `docs/docker.md`: PID 1 is always `ENTRYPOINT ["/usr/bin/dumb-init", "--"]` with the process or start script in `CMD`; `# renovate:` annotations are required only for public-registry image versions held in an `ARG`; comments are one line saying why; runtime-writable paths are chart mounts; never `ARG` a secret; the stack examples follow these rules, and the SPA example no longer copies `nginx.conf` into the image.

## [1.4.0] - 2026-09-25

### Changed

- Excluded `RELEASE_MIGRATION.md` from downloadable GitHub Release assets (`consolidate-assets.sh` and `publish.sh`); preserved in the consolidated release notes body (`CONSOLIDATED_RELEASE_CHANGELOG.md`).
- Removed remote registry `buildcache` layer pushes and pulls (`cache-from` and `cache-to`) from Docker image builds.
- Cleaned up maintainer documentation to remove orphan Python unit test references.
- Bumped container image tags across all workflows to `grootantech/toolkit:1.1.0`.
- Bumped default container base and builder images in `docker.yml` to latest stable releases (`micro-root:1.1.0`, `micro-nginx:1.1.1`, `micro-python-3-12:1.1.1`, `micro-java-25:1.1.1`, `micro-node-24:1.1.1`, `toolkit:1.1.0`).

## [1.3.0] - 2026-09-25

### Fixed

- Exclude `.venv` and `.uv` directories across Python linting jobs (`ruff`, `mypy`, `isort`, `pycodestyle`).

## [1.2.0] - 2026-09-23

### Added

- Allow the chart workflow's `mock-chart` input to name multiple space-separated consumer
  charts; update each dependency tree and run its suite separately so suites are not
  cross-run against unrelated charts.

### Changed

- Use `tests` as the default mock consumer chart directory in the chart workflow.
- Clarify that Python and Node dependency caches are not automatically handed off to the
  separate Docker image-build job, and correct the offline BuildKit examples accordingly.
- Chart workflows now use the dedicated `CHART_REGISTRY`, `CHART_REPOSITORY`,
  `CHART_REGISTRY_USERNAME` and `CHART_REGISTRY_PASSWORD` configuration. Image registry
  configuration is required only when image publishing is enabled.
- Split the README into a task index with focused module, configuration and integration guides.
- Preserve complete examples while reducing the documentation loaded for a single task.
- Describe module responsibilities and clarify source/ref selection independently of example pins.
- Keep OCI publishing mandatory while allowing separate private-dependency registry authentication.

### Fixed

- Discover Dockerfile examples under `docs/` as well as the root README during self-lint.
- Fail chart lookups and promotion on operational errors instead of treating them as absent versions.
- Use chart credentials, not image credentials, when resolving dependencies for chart scans.

## [1.1.0] - 2026-09-22

### Changed

- Updated the self-check workflows to use the local reusable workflow graph.
- Documented the stable 1.0.0 consumer pin and current self-workflow behavior.

## [1.0.0] - 2026-09-19

### Added

- Initial public release.
