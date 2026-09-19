# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `self-version.yml`, `self-lint.yml`, `self-check.yml` and `self-secret-scan.yml`:
  the library's own pipeline split into independently dispatchable dimensions, so
  a developer working on one of them can run just that one. `ci.yml` is now only
  an aggregator over them.
- `scripts/checks/`: the git-tag, chart-version, chart-dependency and image-tag
  guards extracted into standalone scripts.

### Changed

- `check.yml` discovers the guards that apply to the repository and runs them as
  a matrix, so a repository with no chart or no Dockerfile no longer gets
  permanently skipped chart and image jobs in its run graph.
- `init.yml` normalises a path-style development repository suffix to a tag-style
  one on Docker Hub (`/dev` becomes `-dev`), which has no nested repositories.
  Consumers no longer have to set `IMAGE_DEV_REPOSITORY_SUFFIX` per registry.
- `ci.yml` also runs on `dev` pull requests and filters on `.github/**`.
- `cd.yml` ignores `.github/**` on the default branch, so a change confined to
  the pipeline is verified by its pull request and never cuts a release on its
  own, and gains a `workflow_dispatch` trigger for a deliberate release.
- Every job pins its runner to `ubuntu-26.04` instead of tracking
  `ubuntu-latest`, so the platform's migration to Ubuntu 26 cannot change the
  build environment underneath a release. `vars.CI_RUNNER` still overrides it.
- The Dockerfile lint left `docker.yml` entirely. A caller depends on the whole
  workflow, so a lint job inside it put every downstream job — the scan, the
  release guards — behind hadolint, which is not a dependency of any of them.
  `lint.yml` already discovers and lints the Dockerfile, so a caller runs it
  alongside the image build instead of through it. `docker.yml`'s `lint` input
  is gone with it.
- `lint.yml` and `docker-lint.sh` report into the job summary, so every check in
  the library now says what it found without opening the raw log.

### Removed

- The image tar hand-off between build and scan: `docker.yml`'s `save-tar`
  input, `scan.yml`'s `image-artifact` input, and the save / upload / download
  steps behind them. Passing an image as an artifact is a GitLab idiom; on
  GitHub the scan pulls the pushed image from the registry by its
  digest-pinned reference, which is what the build already publishes.

- Every action outside GitHub's own and Marketplace-verified publishers.
  `mikepenz/action-junit-report` and `softprops/action-gh-release` are blocked
  by the common organisation policy that allows only those publishers, and a
  blocked action fails the whole run at startup, before any job begins.

### Fixed

- `secret-scanning.yml`: mark the workspace as a safe git directory before
  scanning. `actions/checkout` only marks it for its own step, so git inside the
  container refused the checkout as dubiously owned and the scan found nothing.
- `scan.yml`, `golang-build.yml`, `java-build.yml`, `node-build.yml` and
  `python-build.yml` publish JUnit results through `scripts/junit-report.sh`,
  which parses the reports with `yq` and posts a check run with annotations and
  a job summary using the `gh` already in the build container.
- `release.yml` publishes through `gh release`, and updates an existing release
  instead of failing, so a re-run of a release is idempotent.
- `secret-scanning.yml`: a pull request now scans its own commit range only when
  both ends of that range resolve in the checkout and the range is non-empty.
  Anything else falls back to the full history with a warning, so an
  unresolvable range can never silently degrade into a scan of nothing.

## [1.0.0] - 2026-09-19

### Added

- Initial public release.
