# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## Unreleased

Three changes require consumer action.

### Status check names changed

Every job name dropped the category prefix its caller already supplied, so branch
protection pinned to an old name must be repointed.

| Workflow | Old | New |
|---|---|---|
| `check.yml` | `Check: Verdict` | `Verdict` |
| `check.yml` | `Check: Git Tag` | `Git Tag Unused` |
| `check.yml` | `Check: Image Not Published` | `Image Tag Unused` |
| `check.yml` | `Check: Chart Not Published` | `Chart Version Unused` |
| `docker.yml` | `Image: Build & Push` / `Image: Smoke Test` / `Image: Promote` | `Build & Push` / `Smoke Test` / `Promote` |
| `chart.yml` | `Chart: Lint` / `Chart: Package` / `Chart: Push` | `Lint` / `Package` / `Push` |
| `scan.yml` | `Scan: <type>` | `<type>` |
| `sbom.yml` | `SBOM: Generate` / `SBOM: Scan` | `Generate` / `Scan` |
| `release.yml` | `Release: Publish` / `Release: Notify Teams` | `Publish` / `Notify Teams` |
| `secret-scanning.yml` | `Security: Secret Scan` | `Secret Scan` |
| `sonarqube.yml` | `Quality: SonarQube` | `SonarQube` |
| `trivy-cache.yml` | `Trivy: Warm Cache` | `Warm Cache` |
| `*-build.yml` | `<Lang>: Build` / `<Lang>: Unit Test` | `Build` / `Unit Test` |
| `terraform-*.yml` | `Terraform: <name>` | `<name>` |

Job **IDs** did not change, so `needs:` and `needs.<id>.outputs` are unaffected.

### Promotion refuses an unscanned image

`docker.yml` and `buildah.yml` gained `require-scan` (default `true`) and `scan-result`.
A release caller must pass the scan job's result:

```yaml
      scan-result: ${{ needs.scan.result }}
```

Without it the promote job fails, naming the fix. Set `require-scan: false` for an
artifact with no scan in its pipeline.

### `docker.yml` no longer takes `lint`

The Dockerfile lint moved to `lint.yml`, which already discovers a Dockerfile. A caller
passing `lint:` to `docker.yml` now gets an unknown-input error; call `lint.yml` alongside
the image build instead. It was removed because a caller depends on the whole workflow, so
a lint job inside it put the scan and the release guards behind hadolint.

Callers should also grant `actions: write` where a scan runs, so `trivy-cache.yml` can
refresh the `trivy-db` entry; without it every scan re-downloads the databases.

## 1.0.0

No migration is required for the initial release.
