# 6. Language Library (No Image, No Chart)

A library ships a distributable, not a container: `init.yml` runs with `ignore-docker` and
`ignore-chart` set to `"true"`, and the whole image and chart half of the library — `docker.yml`,
`buildah.yml`, `chart.yml`, image and config scans, promotion — has no subject. What remains is the
language pair (`python-lint.yml` / `python-build.yml`), supply-chain evidence (`sbom.yml` and a
`license` scan behind `trivy-cache.yml`), `secret-scanning.yml`, `sonarqube.yml`, the `check.yml`
guards and `release.yml`. Swap the two `python-*` calls for the `golang-*`, `node-*` or `java-build.yml`
equivalents; the rest of the shape is unchanged.

```yaml
# .github/workflows/pr.yml
name: CI · PR Verification
run-name: >-
  ${{ github.event_name == 'pull_request'
      && format('PR #{0}: {1} -> {2} ({3})', github.event.pull_request.number, github.head_ref, github.base_ref, github.sha)
      || format('Verify · {0}', github.ref_name) }}

on:
  pull_request:
    branches: [main]
  merge_group:
    types: [checks_requested]

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "true"
      ignore-chart: "true"

  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}

  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  python-lint:
    uses: grootan-devops/github-ci-library/.github/workflows/python-lint.yml@1.0.0
    secrets: inherit

  build:
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/python-build.yml@1.0.0
    secrets: inherit

  sbom:
    needs: trivy-cache
    uses: grootan-devops/github-ci-library/.github/workflows/sbom.yml@1.0.0
    secrets: inherit

  license-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: license

  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit

  sonarqube:
    needs: [init, build]
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

```yaml
# .github/workflows/release.yml
name: CD · Tag, Release & Notify
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  push:
    branches: [main]
    paths-ignore:
      - ".github/**"

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  init:
    if: ${{ !cancelled() }}
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "true"
      ignore-chart: "true"

  release:
    needs: init
    permissions:
      contents: write
      actions: read
    uses: grootan-devops/github-ci-library/.github/workflows/release.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      upstream-run-id: ${{ needs.init.outputs.upstream-run-id }}
      notify: true
```

```yaml
# .github/workflows/build.yml
name: Build · Verify
run-name: "Build · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "true"
      ignore-chart: "true"

  build:
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/python-build.yml@1.0.0
    secrets: inherit
```

```yaml
# .github/workflows/check.yml
name: Check · Release Prerequisites
run-name: "Check · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "true"
      ignore-chart: "true"

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
```

```yaml
# .github/workflows/lint.yml
name: Lint · Config, Docs & Source
run-name: "Lint · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  python-lint:
    uses: grootan-devops/github-ci-library/.github/workflows/python-lint.yml@1.0.0
    secrets: inherit
```

```yaml
# .github/workflows/secret-scan.yml
name: Security · Secret Scan
run-name: "Security · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit
    with:
      full-history: true
```

```yaml
# .github/workflows/sbom.yml
name: Supply Chain · SBOM & Licenses
run-name: "Supply Chain · ${{ github.event_name }} · ${{ github.sha }}"

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

  sbom:
    needs: trivy-cache
    uses: grootan-devops/github-ci-library/.github/workflows/sbom.yml@1.0.0
    secrets: inherit

  license-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: license
```

```yaml
# .github/workflows/sonarqube.yml
name: Quality · SonarQube
run-name: "Quality · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "true"
      ignore-chart: "true"

  build:
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/python-build.yml@1.0.0
    secrets: inherit

  sonarqube:
    needs: [init, build]
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

> [!NOTE]
> There is no `scan-result` wiring anywhere in this shape. The fail-closed promotion gate belongs
> to `docker.yml` and `buildah.yml`; with no image to promote, the release is the git tag plus the
> assets `release.yml` collects.

[Documentation index](../../README.md)
