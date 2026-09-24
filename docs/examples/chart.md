# 3. Helm Chart Only

Configure `CHART_REGISTRY`, `CHART_REPOSITORY` and the chart-specific credentials from the
[configuration guide](../configuration.md#helm-chart-publishing--authentication) before publishing.
Only OCI is supported; GitHub has no automatic registry fallback.

A chart-only repository publishes one OCI artifact and nothing else. `init.yml` reads the
version from `Chart.yaml` and `ignore-docker: "true"` stops it looking for a Dockerfile, so
`chart.yml` is the whole build. `docker.yml` / `buildah.yml` have no subject here, and
neither does `sbom.yml` or `scan-type: license` — both describe an application's dependency
tree, and a chart ships none. What remains is the chart's own pipeline: `lint.yml`,
`chart.yml`, a `config` / `chart` scan, the `check.yml` guards, `secret-scanning.yml`,
`sonarqube.yml` and `release.yml`.

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
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ needs.init.outputs.chart-version }}
      chart-repository: ${{ needs.init.outputs.chart-repository }}

  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  chart:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/chart.yml@1.0.0
    secrets: inherit
    with:
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ needs.init.outputs.chart-push-version }}
      chart-app-version: ${{ needs.init.outputs.chart-app-version }}
      chart-repository: ${{ needs.init.outputs.chart-push-repository }}

  chart-scan:
    needs: [chart, trivy-cache]
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: config
      config-type: chart

  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit

  sonarqube:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

```yaml
# .github/workflows/release.yml
name: CD · Production Release
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  push:
    branches: [main]

concurrency:
  group: "release-${{ github.ref }}"
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

  chart:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/chart.yml@1.0.0
    secrets: inherit
    with:
      is-release: true
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ needs.init.outputs.tag }}
      chart-app-version: ${{ needs.init.outputs.tag }}
      chart-repository: ${{ needs.init.outputs.chart-repository }}
      chart-dev-repository: ${{ needs.init.outputs.chart-dev-repository }}
      release-tag: ${{ needs.init.outputs.tag }}
      candidate-version: ${{ needs.init.outputs.candidate-chart-version }}

  release:
    needs: [init, chart]
    permissions:
      contents: write
      actions: read
    uses: grootan-devops/github-ci-library/.github/workflows/release.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      upstream-run-id: ${{ needs.init.outputs.upstream-run-id }}
```

`chart.yml` · `promote` pulls the exact candidate named by `candidate-version`, repackages
it at the release tag and pushes it to production — the released bytes are the scanned
bytes. It has no `scan-result` input: unlike `docker.yml` / `buildah.yml`, nothing inside it
checks that a scan happened, so the only way to require one on a release is to put a scan
job in the caller and name it in `chart`'s `needs:`. The examples here do not — they take
the **GitLab parity** shape and rely on the pull request's scan.

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

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ needs.init.outputs.chart-version }}
      chart-repository: ${{ needs.init.outputs.chart-repository }}
```

```yaml
# .github/workflows/lint.yml
name: Lint · Config & Documentation
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
```

```yaml
# .github/workflows/chart-scan.yml
name: Scan · Helm Chart
run-name: "Scan · ${{ github.event_name }} · ${{ github.sha }}"

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

  chart-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: config
      config-type: chart
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

  sonarqube:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

> A `type: library` chart (such as `tpllib`) is exempt from the application-chart standard:
> no `values.schema.json`, no `manifest.yaml`, and `check-docs: false` if it ships no
> `README.gotmpl`. A repository whose chart *is* consumed by others should also set
> `run-unittest: true` on `chart.yml` to render mock consumer charts under
> `chart/tests` with `helm unittest --strict`. For multiple chart directories, pass a
> space-separated value such as `mock-chart: "tests tests/extras"`; the reusable workflow
> updates each chart's dependencies and runs each chart's own suite glob separately.

[Documentation index](../../README.md)
