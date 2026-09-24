# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## 1.3.1

No migration is required. Docker image builds no longer push or pull remote registry `buildcache` layers by default.

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
