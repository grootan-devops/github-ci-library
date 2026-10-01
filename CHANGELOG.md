# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
