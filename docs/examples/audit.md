# 7. Security & Code Quality Audit Only

The one shape with no release at all: a repository that ships no artifact but must still be
audited, or a nightly sweep bolted onto a repository that already has one of the six
pipelines above.

```yaml
# .github/workflows/audit.yml
name: Audit · Security & Quality
run-name: "Audit · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit
    with:
      full-history: true

  license-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: license

  sbom:
    needs: trivy-cache
    uses: grootan-devops/github-ci-library/.github/workflows/sbom.yml@1.0.0
    secrets: inherit

  sonarqube:
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
```

No `init.yml`, so no `pull-requests: read` and no version resolution — nothing here is
versioned. `sonarqube.yml` runs without `project-version`, which analyses the branch
without stamping a release version on the Sonar project.

[Documentation index](../../README.md)
