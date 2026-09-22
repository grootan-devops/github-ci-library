# Migration Guide

This document records required consumer actions when upgrading between releases.
Breaking changes must include an entry before release.

## Unreleased

- Repository-specific Markdown rule bypasses are no longer accepted. Fix the Markdown source
  instead; the shared baseline remains limited to the organisation-wide exceptions.
- Repository layout is supplied through reusable workflow inputs. `project-path` now defaults
  to `.` and `chart-dir` to `./chart`; `vars.PROJECT_PATH` and `vars.CHART_DIR` are no longer
  read. Pass `chart-dir` explicitly for charts outside `./chart`.
- Removed the legacy `app-path` and SonarQube `project-key` inputs. Use
  `chart-app-yq-path` and `vars.SONAR_PROJECT_KEY` respectively.
- GitOps endpoints are explicit caller inputs. Pass `argocd-server` and `komodo-server`; the
  reusable workflows no longer fall back to organisation variables for these values.
- The library's own entrypoints are `self-pr.yml` and `self-release.yml`. The reusable
  `release.yml` module remains the public release contract for consumers.

## 1.0.0

No migration is required for the initial release.
