# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

To upgrade, apply every section after your pinned version up to the target, oldest first.
Newer sections are split into **Required** (the upgrade breaks or misbehaves without it),
**Recommended** (aligns an existing project with the current standards) and **Verify**.

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
