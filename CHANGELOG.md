# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Chart workflows now use the dedicated `CHART_REGISTRY`, `CHART_REPOSITORY`,
  `CHART_REGISTRY_USERNAME` and `CHART_REGISTRY_PASSWORD` configuration. Image registry
  configuration is required only when image publishing is enabled.

## [1.2.0] - 2026-09-23

### Changed

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
