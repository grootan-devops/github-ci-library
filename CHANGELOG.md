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

### Fixed

- `secret-scanning.yml`: mark the workspace as a safe git directory before
  scanning. `actions/checkout` only marks it for its own step, so git inside the
  container refused the checkout as dubiously owned and the scan found nothing.
- `secret-scanning.yml`: a pull request now scans its own commit range only when
  both ends of that range resolve in the checkout and the range is non-empty.
  Anything else falls back to the full history with a warning, so an
  unresolvable range can never silently degrade into a scan of nothing.

## [1.0.0] - 2026-09-19

### Added

- Initial public release.
