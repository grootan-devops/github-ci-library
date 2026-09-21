# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## Unreleased

- Repository-specific Markdown rule bypasses are no longer accepted. Fix the Markdown source
  instead; the shared baseline remains limited to the organisation-wide exceptions.
- The library's own entrypoints are now `pr.yml` and `release-trigger.yml`. The reusable
  `release.yml` module remains the public release contract for consumers.

## 1.0.0

No migration is required for the initial release.
