# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## 1.2.0

The documentation restructuring requires no consumer configuration changes. Start at the
README index and follow its task-specific links; update bookmarks to moved sections.

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
